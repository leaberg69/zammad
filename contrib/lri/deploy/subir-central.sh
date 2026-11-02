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

ESPERA=${SUBIR_ESPERA:-2}   # segundos entre tentativas nas esperas limitadas (o teste usa 0)
tunnel_state="não verificado (nada foi parado ainda)"

passo() { printf '== %s\n' "$*"; }
parar() {
  printf 'PARAR: %s. Estado do túnel: %s. Ver "docker compose ... logs" do serviço citado.\n' "$*" "$tunnel_state" >&2
  exit 1
}

tag=$(sed -n 's/^LRI_IMAGE_TAG=//p' .env 2>/dev/null | tail -n 1)
[ -n "$tag" ] || parar "LRI_IMAGE_TAG ausente no .env"
expected_image="$IMAGE_REPO:$tag"

passo "túnel parado"
"${DC[@]}" stop cloudflared || parar "não foi possível parar o cloudflared (pode continuar aberto)"
tunnel_state="parado"

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

passo "Elasticsearch (yellow ou green) e Rails respondendo"
# Nó único: yellow é o normal. Espera até 120 s; red ou tempo esgotado param, com o estado lido.
health=$("${DC[@]}" exec -T zammad-elasticsearch \
  curl -s 'http://127.0.0.1:9200/_cluster/health?wait_for_status=yellow&timeout=120s') \
  || parar "Elasticsearch não responde"
printf '%s' "$health" | grep -Eq '"status" *: *"(green|yellow)"' && printf '%s' "$health" | grep -Eq '"timed_out" *: *false' \
  || parar "Elasticsearch fora de yellow/green: $(printf '%s' "$health" | grep -Eo '"status" *: *"[a-z]+"' || echo 'sem estado')"
"${DC[@]}" exec -T zammad-railsserver curl -sf -o /dev/null http://127.0.0.1:3000 || parar "Rails não responde"

if [ "${REINDEXAR:-0}" = 1 ]; then
  passo "reconstrução do índice de busca"
  "${DC[@]}" exec -T zammad-railsserver bundle exec rake zammad:searchindex:rebuild \
    || parar "reconstrução do índice falhou"
fi

echo "PORTÕES OK ($expected_image)"

if [ "${ABRIR_TUNEL:-0}" != 1 ]; then
  echo "Túnel mantido parado (ABRIR_TUNEL=1 para reabrir)."
  exit 0
fi

passo "reabrindo o túnel"
"${DC[@]}" up -d --force-recreate --no-deps cloudflared || parar "cloudflared não subiu"
tunnel_state="iniciado, sem conexão confirmada"

# Sucesso só com a conexão registrada na Cloudflare; o container cair (token ou config recusados) para na hora.
tunnel_id=$("${DC[@]}" ps -a -q cloudflared)
for _ in $(seq 1 30); do
  if "${DC[@]}" logs cloudflared 2>&1 | grep -q 'Registered tunnel connection'; then
    tunnel_state="aberto"
    echo "TÚNEL ABERTO: conexão registrada na Cloudflare."
    exit 0
  fi
  [ "$(docker inspect -f '{{.State.Running}}' "$tunnel_id")" = true ] \
    || parar "cloudflared encerrou logo depois de iniciar: $("${DC[@]}" logs --tail 5 cloudflared 2>&1 | tr '\n' ' ')"
  sleep "$ESPERA"
done
parar "cloudflared sem conexão registrada depois de 30 tentativas"
