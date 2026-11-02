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
reindex_name="lri-zammad-reindex-$$"
# Container temporário em andamento (init ou reindexação): parar() o encerra e confirma.
temp_container=""
temp_effect=""
temp_child=""
init_state=""

passo() { printf '== %s\n' "$*"; }

# Remove o container temporário e só afirma o encerramento se uma consulta bem-sucedida confirmar que ele sumiu: um
#   init vivo segue migrando o banco, uma reindexação viva segue apagando e recriando índices.
encerrar_temporario() {
  local rm_output remaining
  rm_output=$(docker rm -f "$temp_container" 2>&1)
  if remaining=$(docker ps -a -q --filter "name=^${temp_container}\$" 2>&1) && [ -z "$remaining" ]; then
    init_state="o container $temp_container foi encerrado e removido"
  else
    init_state="NÃO foi possível confirmar o encerramento do container $temp_container ($rm_output; consulta:"
    init_state="$init_state ${remaining:-sem saída}); ele pode continuar $temp_effect: não restaurar nem subir de"
    init_state="$init_state novo antes de conferir com docker ps -a"
  fi
  temp_container=""
}

# Roda um container temporário com prazo, rastreado por nome; qualquer saída diferente de 0 passa por parar(). O
#   cliente fica em segundo plano e o script espera com wait, que um sinal interrompe na hora (um comando em primeiro
#   plano adiaria o trap até o fim do prazo).
temporario() {
  local name=$1 effect=$2 prazo=$3 descricao=$4; shift 4
  temp_container=$name
  temp_effect=$effect
  timeout --kill-after=30 "$prazo" "${DC[@]}" run --rm --no-deps --name "$name" "$@" &
  temp_child=$!
  wait "$temp_child"
  local code=$?
  temp_child=""
  if [ "$code" = 124 ] || [ "$code" = 137 ]; then
    parar "$descricao passou do prazo de $prazo s"
  fi
  [ "$code" = 0 ] || parar "$descricao falhou (código $code)"
  temp_container=""
}

parar() {
  # O cliente em segundo plano (timeout + compose run) é encerrado e esperado antes de mexer no container: uma
  #   criação em andamento termina (ou é abortada) antes do rm e da consulta, e não escapa da limpeza. O timeout tem
  #   --kill-after, então essa espera é limitada.
  if [ -n "$temp_child" ]; then
    kill "$temp_child" 2> /dev/null
    wait "$temp_child" 2> /dev/null
    temp_child=""
  fi
  [ -n "$temp_container" ] && encerrar_temporario
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
    "$*" "${init_state:+ Containers: $init_state.}" "$tunnel_state" >&2
  exit 1
}

# Uma subida por vez neste diretório: duas em paralelo migrariam o mesmo banco e uma abriria o túnel no meio da outra.
#   O lock vale até o fim do processo (o descritor 9 fecha na saída).
exec 9> .subir-central.lock || parar "não foi possível criar .subir-central.lock neste diretório"
flock -n 9 || parar "outra execução do subir-central.sh está em andamento neste diretório; nada foi alterado"

# A imagem esperada vem do próprio compose (aspas, comentários e interpolação como ele os lê), antes de parar algo.
#   config --images também lista as dependências do serviço: só as do fork contam, e todas com a mesma tag.
images=$("${DC[@]}" config --images zammad-railsserver) \
  || parar "o compose não renderizou a configuração (ver a mensagem acima, por exemplo LRI_IMAGE_TAG ausente)"
expected_image=$(printf '%s\n' "$images" | grep "^$IMAGE_REPO:" | sort -u)
if [ -z "$expected_image" ] || [ "$(printf '%s\n' "$expected_image" | wc -l)" != 1 ]; then
  parar "imagem do zammad-railsserver fora de $IMAGE_REPO ou com mais de uma tag: $(printf '%s' "$images" | tr '\n' ' ')"
fi
# O conteúdo, não só o nome: o ID da imagem local dessa tag (baixada e conferida pelo digest no runbook) é o que
#   todo container tem de estar rodando. Nada aqui baixa imagem, então o ID não muda durante a subida.
expected_id=$(docker image inspect -f '{{.Id}}' "$expected_image" 2>&1) \
  || parar "imagem $expected_image não está neste servidor (rodar o pull do runbook antes): $expected_id"

# Interrupção (Ctrl+C, TERM, queda da sessão SSH) em qualquer ponto passa por parar(): encerra o container temporário
#   em andamento, para os processos de fundo e fecha o túnel, conforme o que já tiver sido feito.
trap 'parar "execução interrompida"' INT TERM HUP

passo "túnel parado"
"${DC[@]}" stop cloudflared || parar "não foi possível parar o cloudflared (pode continuar aberto)"
tunnel_state="parado"

# As migrações não podem rodar com processos antigos gravando no banco (tarefas, e-mails, backup).
passo "aplicação parada antes das migrações"
# zammad-init junto: o da stack oficial reinicia sozinho em caso de falha e voltaria a migrar.
"${DC[@]}" stop "${ZAMMAD_SERVICES[@]}" zammad-init || parar "não foi possível parar a aplicação"
running=$("${DC[@]}" ps -q --status running "${ZAMMAD_SERVICES[@]}" 2>&1) \
  || parar "não foi possível confirmar a parada da aplicação: $running"
[ -z "$running" ] || parar "serviços da aplicação ainda em execução depois do stop: $running"

# Um init ou uma reindexação de antes (execução interrompida à força, ou iniciados pelo compose) não podem rodar junto
#   com os novos. Na dúvida (outra stack com serviço zammad-init, consulta que falha), para.
#   Em reinício (o zammad-init oficial tem restart: on-failure) ou pausado conta como ativo.
ATIVOS=(--filter status=running --filter status=restarting --filter status=paused)
old_temps=$( { docker ps -q "${ATIVOS[@]}" --filter label=com.docker.compose.service=zammad-init \
             && docker ps -q "${ATIVOS[@]}" --filter name=lri-zammad-init- \
             && docker ps -q "${ATIVOS[@]}" --filter name=lri-zammad-reindex-; } 2>&1 ) \
  || parar "não foi possível consultar containers de init ou reindexação em execução: $old_temps"
[ -z "$old_temps" ] || parar "há init ou reindexação em execução de antes ($(printf '%s' "$old_temps" | sort -u | tr '\n' ' '));" \
  "esperar terminar ou conferir com docker ps antes de subir"

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
# Qualquer saída diferente de 0 (prazo, erro do cliente Docker ou do próprio init) passa por parar(), que encerra e
#   confirma o container: o cliente pode ter caído com ele ainda migrando.
temporario "$init_name" "migrando o banco" "${INIT_PRAZO:-1800}" "zammad-init" zammad-init

conferir_imagens() {
  local service id image
  for service in "$@"; do
    id=$("${DC[@]}" ps -q "$service")
    [ -n "$id" ] || parar "$service sem container"
    image=$(docker inspect -f '{{.Config.Image}} {{.Image}}' "$id") || parar "não foi possível inspecionar $service"
    [ "$image" = "$expected_image $expected_id" ] \
      || parar "$service rodando '$image', esperado '$expected_image $expected_id' (mesma tag e mesmo conteúdo)"
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
  # Em container próprio e rastreado, como o init: se o cliente cair, parar() encerra e confirma.
  passo "reconstrução do índice de busca, com prazo de ${REINDEX_PRAZO:-3600} s"
  temporario "$reindex_name" "apagando e recriando os índices de busca" "${REINDEX_PRAZO:-3600}" \
    "reconstrução do índice" zammad-railsserver bundle exec rake zammad:searchindex:rebuild
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

# Scheduler e backup não têm healthcheck: depois de uma janela de observação, ainda em execução e sem reinícios.
passo "processos de fundo estáveis (${SUBIR_ESTABILIZAR:-60} s)"
sleep "${SUBIR_ESTABILIZAR:-60}"
for service in "${BACKGROUND_SERVICES[@]}"; do
  id=$("${DC[@]}" ps -q "$service")
  state=$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$id" 2>&1) \
    || parar "não foi possível conferir $service: $state"
  [ "$state" = "true 0" ] \
    || parar "$service instável (em execução, reinícios: $state): $("${DC[@]}" logs --tail 5 "$service" 2>&1 | tr '\n' ' ')"
done

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
