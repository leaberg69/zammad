#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Sobe a central com portões (docs/lri/GO-LIVE.md): go-live, atualização de imagem e retorno usam esta sequência.
# Roda no diretório da central (docker-compose.yml oficial, docker-compose.lri.yml e .env). O túnel fica parado do
# início ao fim e só reabre com ABRIR_TUNEL=1 e todos os portões aprovados; qualquer falha para com o motivo.
#
#   ABRIR_TUNEL=1   reabre o cloudflared no fim (sem isso, deixa parado para conferência manual)
#   REINDEXAR=1     reconstrói o índice de busca (obrigatório depois de restaurar o banco)

set -u

DC=(docker compose -f docker-compose.yml -f docker-compose.lri.yml)
IMAGE_REPO=ghcr.io/leaberg69/zammad-lri
ZAMMAD_SERVICES=(zammad-railsserver zammad-websocket zammad-scheduler zammad-nginx zammad-backup)
DEPENDENCIES=(zammad-postgresql zammad-redis zammad-memcached zammad-elasticsearch)

passo() { printf '== %s\n' "$*"; }
parar() {
  printf 'PARAR: %s. O túnel continua parado; ver "docker compose ... logs" do serviço citado.\n' "$*" >&2
  exit 1
}

tag=$(sed -n 's/^LRI_IMAGE_TAG=//p' .env 2>/dev/null | tail -n 1)
[ -n "$tag" ] || parar "LRI_IMAGE_TAG ausente no .env"
expected_image="$IMAGE_REPO:$tag"

passo "túnel parado"
"${DC[@]}" stop cloudflared || parar "não foi possível parar o cloudflared"

passo "checagem da tag $tag"
"${DC[@]}" run --rm --no-deps lri-config-check || parar "tag recusada pelo lri-config-check"

passo "dependências (banco, cache, Redis, Elasticsearch)"
"${DC[@]}" up -d --wait --wait-timeout 600 "${DEPENDENCIES[@]}" || parar "dependências não ficaram prontas"

passo "zammad-init da imagem escolhida (migrações)"
"${DC[@]}" run --rm --no-deps zammad-init || parar "zammad-init falhou"

passo "aplicação"
"${DC[@]}" up -d --force-recreate --no-deps --wait --wait-timeout 900 "${ZAMMAD_SERVICES[@]}" \
  || parar "serviços da aplicação não ficaram saudáveis"

passo "imagem de cada serviço"
for service in "${ZAMMAD_SERVICES[@]}"; do
  id=$("${DC[@]}" ps -q "$service")
  [ -n "$id" ] || parar "$service sem container"
  image=$(docker inspect -f '{{.Config.Image}}' "$id") || parar "não foi possível inspecionar $service"
  [ "$image" = "$expected_image" ] || parar "$service rodando $image, esperado $expected_image"
done

passo "Elasticsearch e Rails respondendo"
"${DC[@]}" exec -T zammad-elasticsearch curl -sf -o /dev/null http://127.0.0.1:9200/_cluster/health \
  || parar "Elasticsearch não responde"
"${DC[@]}" exec -T zammad-railsserver curl -sf -o /dev/null http://127.0.0.1:3000 || parar "Rails não responde"

if [ "${REINDEXAR:-0}" = 1 ]; then
  passo "reconstrução do índice de busca"
  "${DC[@]}" exec -T zammad-railsserver bundle exec rake zammad:searchindex:rebuild \
    || parar "reconstrução do índice falhou"
fi

echo "PORTÕES OK ($expected_image)"

if [ "${ABRIR_TUNEL:-0}" = 1 ]; then
  passo "reabrindo o túnel"
  "${DC[@]}" up -d --force-recreate --no-deps cloudflared || parar "cloudflared não subiu"
else
  echo "Túnel mantido parado (ABRIR_TUNEL=1 para reabrir)."
fi
