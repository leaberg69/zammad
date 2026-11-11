#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Sobe a central com portões (docs/lri/GO-LIVE.md): go-live, atualização de imagem e retorno usam esta sequência.
# Roda no diretório da central (docker-compose.yml oficial, docker-compose.lri.yml e .env). O túnel fica parado do
# início ao fim e só reabre com ABRIR_TUNEL=1 e todos os portões aprovados; qualquer falha para com o motivo.
#
#   ABRIR_TUNEL=1   libera no fim: sobe os processos de fundo e reabre o cloudflared (sem isso, os dois ficam
#                   parados para conferência manual)
#   REINDEXAR=1     reconstrói o índice de busca (obrigatório depois de restaurar o banco)
#   SUBIR_ES_PRAZO  prazo total, em segundos, da espera pelo Elasticsearch em yellow/green (padrão 300)
#   SUBIR_PRAZO_TENTATIVA  prazo, em segundos, de cada verificação e consulta ao Docker (padrão 15)

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
ES_PRAZO=${SUBIR_ES_PRAZO:-300}
PRAZO_TENTATIVA=${SUBIR_PRAZO_TENTATIVA:-15}   # prazo de cada verificação e de cada consulta ao Docker
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
# Decimal de 1 a 99999 sem zero à esquerda: o Bash leria 08 como octal (erro) e 010 como 8, e um prazo 0 desliga
#   o timeout.
for prazo_var in SUBIR_ES_PRAZO:"$ES_PRAZO" SUBIR_PRAZO_TENTATIVA:"$PRAZO_TENTATIVA"; do
  [[ "${prazo_var#*:}" =~ ^[1-9][0-9]{0,4}$ ]] || parar "${prazo_var%%:*} inválido: '${prazo_var#*:}' (segundos inteiros," \
    "de 1 a 99999, sem zero à esquerda); nada foi alterado"
done

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

# Antes do init, que espera o Elasticsearch sem prazo. A stack oficial não tem healthcheck nele, então o --wait acima
#   só garante o container em execução: recém-criado, a JVM ainda não abriu a 9200. A espera é a do próprio
#   _cluster/health (wait_for_status), repetida até o prazo total; porta fechada é "ainda subindo", não falha.
#   Nó único: yellow é o normal. Reinício ou morte do container durante a espera param na hora.
es_id=""
es_estado=""
es_ultima="nenhuma consulta concluída"

# Chamada ao Docker com prazo: um daemon pendurado não prende a espera nem o diagnóstico. Sem resposta, a saída diz isso.
#   LIMITE=<s> limitado ... encurta o prazo da chamada.
#   No sucesso devolve só o stdout (um aviso do compose no stderr não contamina um ID); na falha, também o stderr.
limitado() {
  local saida codigo erro limite=${LIMITE:-$PRAZO_TENTATIVA}
  # --kill-after: um cliente que ignore o TERM é morto 5 s depois, então o prazo vale com no máximo essa folga.
  saida=$(timeout --kill-after=5 "$limite" "$@" 2> .subir-central.err)
  codigo=$?
  erro=$(tr '\n' ' ' < .subir-central.err 2> /dev/null | tail -c 300)
  if [ "$codigo" = 124 ] || [ "$codigo" = 137 ]; then
    saida="sem resposta do Docker em $limite s"
  elif [ "$codigo" != 0 ]; then
    saida="${saida:+$saida }${erro:-sem mensagem de erro}"
  fi
  printf '%s' "$saida"
  return "$codigo"
}

# Estado atual do container, conferido contra o da primeira inspeção (reinício ou saída param a espera).
#   A inspeção nunca vai além do prazo total da espera.
conferir_container_es() {
  local limite=$PRAZO_TENTATIVA resta=$((ES_PRAZO - (SECONDS - es_inicio)))
  [ "$resta" -ge "$limite" ] || limite=$((resta > 1 ? resta : 1))
  es_estado=$(LIMITE=$limite limitado docker inspect -f '{{.State.Status}} {{.RestartCount}} {{.State.OOMKilled}}' \
    "$es_id") || falha_elasticsearch "não foi possível inspecionar o container ($es_estado)"
  [ -n "$es_reinicios" ] || es_reinicios=$(printf '%s' "$es_estado" | awk '{print $2}')
  case "$es_estado" in
    "running $es_reinicios "*) ;;
    running\ * | restarting\ *) falha_elasticsearch "o container reiniciou durante a espera" ;;
    *) falha_elasticsearch "o container saiu de execução" ;;
  esac
}

# Resposta de saúde para o diagnóstico: status e timed_out sempre visíveis, e o corte do resto declarado.
resumo_saude() {
  local resposta status timed_out corte=""
  resposta=$(printf '%s' "$1" | tr '\n' ' ')
  status=$(printf '%s' "$resposta" | grep -Eo '"status" *: *"[a-z]+"' | head -n 1)
  timed_out=$(printf '%s' "$resposta" | grep -Eo '"timed_out" *: *(true|false)' | head -n 1)
  [ "${#resposta}" -le 300 ] || corte=" [cortada: ${#resposta} caracteres, mostrados os 300 primeiros]"
  printf '%s%s%s' "${status:+$status, }${timed_out:+$timed_out; }" "${resposta:0:300}" "$corte"
}

falha_elasticsearch() {
  local env_es heap memoria log_es diag=$((PRAZO_TENTATIVA < 5 ? PRAZO_TENTATIVA : 5))
  # Cada dado do diagnóstico tem até 5 s; o que não vier fica como "não lido", com o motivo.
  if env_es=$(LIMITE=$diag limitado docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$es_id"); then
    heap=$(printf '%s\n' "$env_es" | sed -n 's/^ES_JAVA_OPTS=//p')
    heap=${heap:-padrão da imagem (ES_JAVA_OPTS ausente)}
  else
    heap="não lido ($env_es)"
  fi
  if ! memoria=$(LIMITE=$diag limitado docker inspect -f '{{.HostConfig.Memory}}' "$es_id"); then
    memoria="não lido ($memoria)"
  elif [ "$memoria" -gt 0 ] 2> /dev/null; then
    memoria="$((memoria / 1048576)) MB"
  else
    memoria="sem limite ($memoria)"
  fi
  log_es=$(LIMITE=$diag limitado "${DC[@]}" logs --tail 5 zammad-elasticsearch | tr '\n' ' ')
  [ "${#log_es}" -le 600 ] || log_es="[últimos 600 de ${#log_es} caracteres] ${log_es: -600}"
  parar "Elasticsearch não ficou em yellow/green ($((SECONDS - es_inicio)) s de espera, prazo $ES_PRAZO s): $1." \
    "Container: estado=$(printf '%s' "$es_estado" | awk '{print $1" reinícios="$2" OOMKilled="$3}')." \
    "Última consulta de saúde: $es_ultima. Configuração: heap $heap, limite do container $memoria." \
    "Log: $log_es. Dica: a VPS de 16 GB é compartilhada; conferir free -m e docker stats. O heap fica em 1 GB" \
    "(teto do PLANO, não aumentar); com OOMKilled=true ou reinícios, liberar memória no host antes de subir de novo"
}

passo "Elasticsearch em yellow ou green (até $ES_PRAZO s)"
es_inicio=$SECONDS
es_reinicios=""
es_id=$(LIMITE=$((PRAZO_TENTATIVA < ES_PRAZO ? PRAZO_TENTATIVA : ES_PRAZO)) limitado "${DC[@]}" ps -q zammad-elasticsearch) \
  || parar "não foi possível localizar o zammad-elasticsearch: $es_id"
[ -n "$es_id" ] || parar "zammad-elasticsearch sem container depois de subir as dependências"
while :; do
  conferir_container_es
  restante=$((ES_PRAZO - (SECONDS - es_inicio)))
  [ "$restante" -gt 0 ] || falha_elasticsearch "prazo esgotado"
  # Janela por tentativa (2 x SUBIR_PRAZO_TENTATIVA, dentro do restante): uma conexão aceita sem resposta ou um
  #   docker exec travado são cortados nela, e o container é reinspecionado antes da próxima. O timeout= do servidor
  #   deixa 5 s para o docker exec, para a resposta "timed_out" chegar inteira antes do corte.
  janela=$((2 * PRAZO_TENTATIVA < restante ? 2 * PRAZO_TENTATIVA : restante))
  servidor=$((janela > 6 ? janela - 5 : 1))
  resposta=$(timeout --kill-after=5 "$janela" "${DC[@]}" exec -T zammad-elasticsearch curl -sS --max-time "$janela" \
    "http://127.0.0.1:9200/_cluster/health?wait_for_status=yellow&timeout=${servidor}s" 2>&1)
  codigo=$?
  # Registrada antes de decidir: se a inspeção seguinte falhar, o diagnóstico mostra esta resposta.
  if [ "$codigo" = 124 ] || [ "$codigo" = 137 ]; then
    es_ultima="sem resposta em $janela s"
  else
    es_ultima="código $codigo: $(resumo_saude "$resposta")"
  fi
  if [ "$codigo" = 0 ] && printf '%s' "$resposta" | grep -Eq '"status" *: *"(green|yellow)"' \
     && printf '%s' "$resposta" | grep -Eq '"timed_out" *: *false'; then
    # A resposta pode ser de uma instância nova: um reinício durante a consulta também para. O prazo é conferido
    #   depois da inspeção, que também gasta tempo.
    conferir_container_es
    [ $((SECONDS - es_inicio)) -le "$ES_PRAZO" ] || falha_elasticsearch "prazo esgotado (a resposta chegou depois dele)"
    echo "Elasticsearch pronto em $((SECONDS - es_inicio)) s: $(printf '%s' "$resposta" | grep -Eo '"status" *: *"[a-z]+"')"
    break
  fi
  # Intervalo para a porta ainda fechada, quando o curl volta na hora; nunca além do prazo.
  restante=$((ES_PRAZO - (SECONDS - es_inicio)))
  [ "$restante" -gt 0 ] && sleep $((ESPERA < restante ? ESPERA : restante))
done

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
ate_responder() {
  local descricao=$1 saida codigo motivo=""; shift
  for _ in $(seq 1 "$TENTATIVAS"); do
    saida=$(timeout --kill-after=5 "$PRAZO_TENTATIVA" "$@" 2>&1) && return 0
    codigo=$?
    # Motivo da última tentativa: tempo esgotado ou o código e o fim da mensagem de erro.
    if [ "$codigo" = 124 ] || [ "$codigo" = 137 ]; then
      motivo="sem resposta em $PRAZO_TENTATIVA s"
    else
      motivo="código $codigo: $(printf '%s' "$saida" | tr '\n' ' ' | tail -c 300)"
    fi
    sleep "$ESPERA"
  done
  parar "$descricao não respondeu depois de $TENTATIVAS tentativas de até $PRAZO_TENTATIVA s (última: $motivo)"
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

# Guarda desligada (fase A) só com o túnel exclusivamente no nome interno e Access obrigatório: um LRI_ZONE_GUARD=off
#   esquecido, com os portais no config.yml, publicaria a central sem a separação de zonas.
passo "guarda de zona compatível com os nomes do túnel"
rails_env=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$("${DC[@]}" ps -q zammad-railsserver)" 2>&1) \
  || parar "não foi possível ler o ambiente do zammad-railsserver: $rails_env"
guard=$(printf '%s\n' "$rails_env" | sed -n 's/^LRI_ZONE_GUARD=//p')
internal_host=$(printf '%s\n' "$rails_env" | sed -n 's#^LRI_INTERNAL_URL=https://##p')
access_team=$(printf '%s\n' "$rails_env" | sed -n 's/^LRI_ACCESS_TEAM_DOMAIN=\(.*\)\.cloudflareaccess\.com$/\1/p')
access_aud=$(printf '%s\n' "$rails_env" | sed -n 's/^LRI_ACCESS_AUD=//p')
if [ "$guard" != enforce ]; then
  if [ -z "$internal_host" ] || [ -z "$access_team" ] || [ -z "$access_aud" ]; then
    parar "guarda desligada (LRI_ZONE_GUARD=$guard) e o railsserver sem LRI_INTERNAL_URL, LRI_ACCESS_TEAM_DOMAIN ou LRI_ACCESS_AUD"
  fi
  # O YAML é lido de verdade pelo validador que vem na própria imagem (mesmo commit), sem rede.
  validacao=$(docker run --rm --network none --entrypoint ruby -v "$PWD/cloudflared:/etc/lri-cloudflared:ro" \
    "$expected_image" contrib/lri/deploy/validar_tunel_fase_a.rb /etc/lri-cloudflared/config.yml \
    "$internal_host" "$access_team" "$access_aud" 2>&1) \
    || parar "guarda de zona desligada (LRI_ZONE_GUARD=$guard) e o túnel não está só no nome interno: $validacao;" \
      "corrigir o config.yml ou ligar a guarda (fase B)"
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
  if timeout --kill-after=5 "$PRAZO_TENTATIVA" "${DC[@]}" exec -T zammad-nginx \
       curl -sf --max-time 5 -o /dev/null http://127.0.0.1:20241/ready > /dev/null 2>&1; then
    tunnel_state="aberto"
    echo "TÚNEL ABERTO: conexão ativa com a Cloudflare (/ready)."
    exit 0
  fi
  sleep "$ESPERA"
done
parar "cloudflared sem conexão ativa (/ready) depois de $TENTATIVAS tentativas: $("${DC[@]}" logs --tail 5 cloudflared 2>&1 | tr '\n' ' ')"
