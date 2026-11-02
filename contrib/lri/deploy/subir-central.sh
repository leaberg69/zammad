#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Sobe a central com portões (docs/lri/GO-LIVE.md): go-live, atualização de imagem e retorno usam esta sequência.
# Roda no diretório da central (docker-compose.yml oficial, docker-compose.lri.yml e .env). O túnel fica parado do
# início ao fim e só reabre com ABRIR_TUNEL=1 e todos os portões aprovados; qualquer falha para com o motivo.
#
#   ABRIR_TUNEL=1   libera no fim: sobe os processos de fundo e reabre o cloudflared (sem isso, os dois ficam
#                   parados para conferência manual)
#   REINDEXAR=1     reconstrói o índice de busca (obrigatório depois de restaurar o banco)

set -u

DC=(docker compose -f docker-compose.yml -f docker-compose.lri.yml)
IMAGE_REPO=ghcr.io/leaberg69/zammad-lri
# Web sobe para os portões; os de fundo (tarefas, e-mails, backup) só na liberação, porque fechar o túnel não impede
#   o que eles fazem para fora.
WEB_SERVICES=(zammad-railsserver zammad-websocket zammad-nginx)
BACKGROUND_SERVICES=(zammad-scheduler zammad-backup)
ZAMMAD_SERVICES=("${WEB_SERVICES[@]}" "${BACKGROUND_SERVICES[@]}")
background_started=0
DEPENDENCIES=(zammad-postgresql zammad-redis zammad-memcached zammad-elasticsearch)

ESPERA=${SUBIR_ESPERA:-2}   # segundos entre tentativas nas esperas limitadas (o teste usa 0)
tunnel_state="não verificado (nada foi parado ainda)"
tunnel_started=0
init_name="lri-zammad-init-$$"
init_running=0
init_state=""

passo() { printf '== %s\n' "$*"; }

# Remove o container do init e só afirma o encerramento se uma consulta bem-sucedida confirmar que ele sumiu: um
#   init vivo segue migrando o banco.
encerrar_init() {
  local rm_output remaining
  rm_output=$(docker rm -f "$init_name" 2>&1)
  if remaining=$(docker ps -a -q --filter "name=^${init_name}\$" 2>&1) && [ -z "$remaining" ]; then
    init_state="o container $init_name foi encerrado e removido"
  else
    init_state="NÃO foi possível confirmar o encerramento do container $init_name ($rm_output; consulta:"
    init_state="$init_state ${remaining:-sem saída}); ele pode continuar migrando o banco: não restaurar nem subir de"
    init_state="$init_state novo antes de conferir com docker ps -a"
  fi
  init_running=0
}

parar() {
  [ "$init_running" = 1 ] && encerrar_init
  # Falha depois da liberação: os processos de fundo param de novo.
  if [ "$background_started" = 1 ]; then
    if "${DC[@]}" stop "${BACKGROUND_SERVICES[@]}" > /dev/null 2>&1; then
      init_state="${init_state:+$init_state; }processos de fundo parados de novo"
    else
      init_state="${init_state:+$init_state; }NÃO foi possível parar os processos de fundo (scheduler, backup)"
    fi
  fi
  # Falha depois de reabrir o túnel: fecha de novo, para ele não abrir sozinho mais tarde.
  if [ "$tunnel_started" = 1 ]; then
    if "${DC[@]}" stop cloudflared > /dev/null 2>&1; then
      tunnel_state="parado de novo depois da falha"
    else
      tunnel_state="PODE ESTAR ABERTO: falhou ao parar o cloudflared depois da falha"
    fi
  fi
  printf 'PARAR: %s.%s Estado do túnel: %s. Ver "docker compose ... logs" do serviço citado.\n' \
    "$*" "${init_state:+ Init: $init_state.}" "$tunnel_state" >&2
  exit 1
}

# A imagem esperada vem do próprio compose (aspas, comentários e interpolação como ele os lê), antes de parar algo.
#   config --images também lista as dependências do serviço: só as do fork contam, e todas com a mesma tag.
images=$("${DC[@]}" config --images zammad-railsserver) \
  || parar "o compose não renderizou a configuração (ver a mensagem acima, por exemplo LRI_IMAGE_TAG ausente)"
expected_image=$(printf '%s\n' "$images" | grep "^$IMAGE_REPO:" | sort -u)
if [ -z "$expected_image" ] || [ "$(printf '%s\n' "$expected_image" | wc -l)" != 1 ]; then
  parar "imagem do zammad-railsserver fora de $IMAGE_REPO ou com mais de uma tag: $(printf '%s' "$images" | tr '\n' ' ')"
fi

# Interrupção (Ctrl+C, TERM) em qualquer ponto passa por parar(), que fecha o túnel se ele já tiver sido reaberto.
trap 'parar "execução interrompida"' INT TERM

passo "túnel parado"
"${DC[@]}" stop cloudflared || parar "não foi possível parar o cloudflared (pode continuar aberto)"
tunnel_state="parado"

# As migrações não podem rodar com processos antigos gravando no banco (tarefas, e-mails, backup).
passo "aplicação parada antes das migrações"
"${DC[@]}" stop "${ZAMMAD_SERVICES[@]}" || parar "não foi possível parar a aplicação"
running=$("${DC[@]}" ps -q --status running "${ZAMMAD_SERVICES[@]}" 2>&1) \
  || parar "não foi possível confirmar a parada da aplicação: $running"
[ -z "$running" ] || parar "serviços da aplicação ainda em execução depois do stop: $running"

passo "checagem da tag ${expected_image#"$IMAGE_REPO":}"
"${DC[@]}" run --rm --no-deps lri-config-check || parar "tag recusada pelo lri-config-check"

passo "dependências (banco, cache, Redis, Elasticsearch)"
"${DC[@]}" up -d --wait --wait-timeout 600 "${DEPENDENCIES[@]}" || parar "dependências não ficaram prontas"

# Antes do init, que espera o Elasticsearch sem prazo. Nó único: yellow é o normal; red ou tempo esgotado param.
passo "Elasticsearch em yellow ou green"
health=$(timeout 180 "${DC[@]}" exec -T zammad-elasticsearch \
  curl -s 'http://127.0.0.1:9200/_cluster/health?wait_for_status=yellow&timeout=120s') \
  || parar "Elasticsearch não responde"
if ! printf '%s' "$health" | grep -Eq '"status" *: *"(green|yellow)"' \
   || ! printf '%s' "$health" | grep -Eq '"timed_out" *: *false'; then
  parar "Elasticsearch fora de yellow/green: $(printf '%s' "$health" | grep -Eo '"status" *: *"[a-z]+"' || echo 'sem estado')"
fi

passo "zammad-init da imagem escolhida (migrações), com prazo de ${INIT_PRAZO:-1800} s"
init_running=1
timeout --kill-after=30 "${INIT_PRAZO:-1800}" "${DC[@]}" run --rm --no-deps --name "$init_name" zammad-init
init_code=$?
# Qualquer saída diferente de 0 (prazo, erro do cliente Docker ou do próprio init) passa por encerrar_init(), via
#   parar(): o cliente pode ter caído com o container ainda migrando.
if [ "$init_code" = 124 ] || [ "$init_code" = 137 ]; then
  parar "zammad-init passou do prazo de ${INIT_PRAZO:-1800} s"
fi
[ "$init_code" = 0 ] || parar "zammad-init falhou (código $init_code)"
init_running=0

conferir_imagens() {
  local service id image
  for service in "$@"; do
    id=$("${DC[@]}" ps -q "$service")
    [ -n "$id" ] || parar "$service sem container"
    image=$(docker inspect -f '{{.Config.Image}}' "$id") || parar "não foi possível inspecionar $service"
    [ "$image" = "$expected_image" ] || parar "$service rodando $image, esperado $expected_image"
  done
}

passo "aplicação web (processos de fundo continuam parados)"
"${DC[@]}" up -d --force-recreate --no-deps --wait --wait-timeout 900 "${WEB_SERVICES[@]}" \
  || parar "serviços web não ficaram saudáveis"
passo "imagem de cada serviço web"
conferir_imagens "${WEB_SERVICES[@]}"

# Nginx, WebSocket e o túnel não têm healthcheck na stack oficial: confere de dentro, com tentativas limitadas e
#   prazo por tentativa (uma conexão aceita sem resposta não prende o script).
TENTATIVAS=${SUBIR_TENTATIVAS:-30}
PRAZO_TENTATIVA=${SUBIR_PRAZO_TENTATIVA:-15}
ate_responder() {
  local descricao=$1; shift
  for _ in $(seq 1 "$TENTATIVAS"); do
    timeout "$PRAZO_TENTATIVA" "$@" > /dev/null 2>&1 && return 0
    sleep "$ESPERA"
  done
  parar "$descricao não respondeu depois de $TENTATIVAS tentativas de até $PRAZO_TENTATIVA s"
}

passo "Rails, WebSocket e Nginx respondendo"
ate_responder "Rails" "${DC[@]}" exec -T zammad-railsserver curl -sf --max-time 10 -o /dev/null http://127.0.0.1:3000
ate_responder "WebSocket (porta 6042)" "${DC[@]}" exec -T zammad-websocket \
  timeout 10 bash -c 'exec 3<>/dev/tcp/127.0.0.1/6042'
# shellcheck disable=SC2016 # $LRI_FQDN é expandido dentro do container do Nginx
ate_responder "Nginx (listener público 127.0.0.1:8081)" "${DC[@]}" exec -T zammad-nginx \
  sh -c 'curl -sf --max-time 10 -o /dev/null -H "Host: $LRI_FQDN" http://127.0.0.1:8081/'

if [ "${REINDEXAR:-0}" = 1 ]; then
  passo "reconstrução do índice de busca"
  "${DC[@]}" exec -T zammad-railsserver bundle exec rake zammad:searchindex:rebuild \
    || parar "reconstrução do índice falhou"
fi

echo "PORTÕES OK ($expected_image)"

if [ "${ABRIR_TUNEL:-0}" != 1 ]; then
  echo "Processos de fundo e túnel mantidos parados (ABRIR_TUNEL=1 para liberar)."
  exit 0
fi

passo "processos de fundo (liberação)"
background_started=1
"${DC[@]}" up -d --force-recreate --no-deps --wait --wait-timeout 900 "${BACKGROUND_SERVICES[@]}" \
  || parar "processos de fundo não ficaram prontos"
conferir_imagens "${BACKGROUND_SERVICES[@]}"

passo "reabrindo o túnel"
tunnel_started=1
"${DC[@]}" up -d --force-recreate --no-deps cloudflared || parar "cloudflared não subiu"
tunnel_state="iniciado, sem conexão confirmada"

# Sucesso só com o container em execução E o /ready das métricas do cloudflared respondendo 200, que exige uma
#   conexão ativa agora (um registro antigo no log não vale). As métricas ficam em 127.0.0.1:20241 do namespace do
#   Nginx, consultadas de dentro dele. Container parado ou tempo esgotado: falha, e parar() fecha o túnel de novo.
tunnel_id=$("${DC[@]}" ps -a -q cloudflared)
for _ in $(seq 1 "$TENTATIVAS"); do
  [ "$(docker inspect -f '{{.State.Running}}' "$tunnel_id")" = true ] \
    || parar "cloudflared não está em execução: $("${DC[@]}" logs --tail 5 cloudflared 2>&1 | tr '\n' ' ')"
  if timeout "$PRAZO_TENTATIVA" "${DC[@]}" exec -T zammad-nginx \
       curl -sf --max-time 5 -o /dev/null http://127.0.0.1:20241/ready > /dev/null 2>&1; then
    tunnel_state="aberto"
    echo "TÚNEL ABERTO: conexão ativa com a Cloudflare (/ready)."
    exit 0
  fi
  sleep "$ESPERA"
done
parar "cloudflared sem conexão ativa (/ready) depois de $TENTATIVAS tentativas: $("${DC[@]}" logs --tail 5 cloudflared 2>&1 | tr '\n' ' ')"
