#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/
#
# Teste do Nginx das zonas: renderiza contrib/lri/deploy/nginx com o nginx-entrypoint.sh num container nginx, liga
# um upstream de eco no mesmo namespace de rede e confere cabeçalhos, Origin, redirecionamentos e bloqueios. Depois,
# com upstreams que recusam a conexão ou não respondem, confere o diagnóstico da rota do monitor sem o token no log.
# Uso: contrib/lri/deploy/test/nginx_zones_test.sh   (precisa de Docker)

set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash no Windows: não converter caminhos dos volumes

DEPLOY=$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))
NAME="lri-nginx-test-$$"
KEY="chave-de-teste-0123456789abcdefghijkl"
MONITOR_TOKEN="tokdomonitor_0123456789-abcdef" # o mesmo de check_nginx_zones.py
NGINX_IMAGE=${NGINX_IMAGE:-nginx:1.27-alpine}
PYTHON_IMAGE=${PYTHON_IMAGE:-python:3.12-alpine}

cleanup() {
  docker rm -f "$NAME-echo" "$NAME-nginx" "$NAME-mudo" "$NAME-nginx-recusa" "$NAME-nginx-prazo" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Sobe o Nginx das zonas no namespace de rede do container $2, com o railsserver na porta $3, e espera os listeners.
subir_nginx() {
  local nome=$1 rede=$2 porta_rails=$3
  docker run -d --name "$nome" --network "container:$rede" \
    -v "$DEPLOY:/opt/zammad/contrib/lri/deploy:ro" \
    -e LRI_ZONE_KEY="$KEY" \
    -e LRI_FQDN=suporte.lri.com.br \
    -e LRI_INTERNAL_HOST=atendimento.lri.com.br \
    -e LRI_MW_HOST=suporte.meanwellbrasil.com.br \
    -e LRI_PUBLIC_HOSTS="suporte.lri.com.br suporte.meanwellbrasil.com.br suporte.ird.net.br" \
    -e ZAMMAD_RAILSSERVER_HOST=127.0.0.1 -e ZAMMAD_RAILSSERVER_PORT="$porta_rails" -e ZAMMAD_WEBSOCKET_HOST=127.0.0.1 \
    -e LRI_NGINX_DRY_RUN=1 -e LRI_NGINX_SITE=/etc/nginx/conf.d/default.conf \
    "$NGINX_IMAGE" sh -c '
      # Como o nginx.conf do Debian da imagem: server_tokens já definido no http (o template não pode repeti-lo).
      echo "server_tokens off;" > /etc/nginx/conf.d/00-distro.conf
      /opt/zammad/contrib/lri/deploy/nginx-entrypoint.sh && nginx -t && exec nginx -g "daemon off;"' >/dev/null
  for _ in $(seq 1 20); do
    docker exec "$nome" sh -c 'nc -z 127.0.0.1 8081 && nc -z 127.0.0.1 8082' 2>/dev/null && return 0
    sleep 1
  done
  echo "Nginx $nome não subiu; log:" >&2
  docker logs "$nome" >&2
  exit 1
}

docker run -d --name "$NAME-echo" -v "$DEPLOY:/deploy:ro" "$PYTHON_IMAGE" python /deploy/test/echo_upstream.py >/dev/null
subir_nginx "$NAME-nginx" "$NAME-echo" 3000
for _ in $(seq 1 20); do
  docker exec "$NAME-nginx" nc -z 127.0.0.1 3000 2>/dev/null && break
  sleep 1
done

docker run --rm --network "container:$NAME-echo" -v "$DEPLOY:/deploy:ro" "$PYTHON_IMAGE" python /deploy/test/check_nginx_zones.py "$KEY"

# O token do monitor não pode aparecer no log do Nginx. Comparação sem pipeline: com pipefail, um grep -q que acha
#   cedo daria SIGPIPE a quem escreve e esconderia o achado.
sem_token_no_log() {
  local log
  log=$(docker logs "$1" 2>&1)
  if [[ "$log" == *"$MONITOR_TOKEN"* ]]; then
    echo "FALHA  o token do monitor apareceu no log do Nginx ($2)" >&2
    exit 1
  fi
  echo "OK     o token do monitor não aparece no log do Nginx ($2)"
}
sem_token_no_log "$NAME-nginx" "upstream respondendo"

# Upstream que aceita a conexão e nunca responde (porta 3000) e porta sem ninguém (3001), no namespace de um
#   container próprio: a rota do monitor responde 502/504, o log de erro traz a causa e não traz o token.
docker run -d --name "$NAME-mudo" "$PYTHON_IMAGE" python -c '
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 3000))
s.listen()
abertas = []
while True:
    abertas.append(s.accept())' >/dev/null

falha_upstream() {
  local nome=$1 porta=$2 esperado_status=$3 causa=$4 log status
  subir_nginx "$nome" "$NAME-mudo" "$porta"
  status=$(docker exec "$nome" sh -c "wget -S -q -O /dev/null -T 60 --header 'Host: atendimento.lri.com.br' \
    --header 'X-LRI-Monitor-Token: $MONITOR_TOKEN' http://127.0.0.1:8082/lri-monitor/health_check 2>&1 | grep -o 'HTTP/[0-9.]* [0-9]*' | tail -n 1" || true)
  # Uso errado, com o token na URL: recusado antes do upstream, então nem a linha de erro o grava.
  docker exec "$nome" wget -q -O /dev/null -T 60 --header 'Host: atendimento.lri.com.br' \
    "http://127.0.0.1:8082/lri-monitor/health_check?token=$MONITOR_TOKEN" > /dev/null 2>&1 || true
  log=$(docker logs "$nome" 2>&1)
  if [[ "$status" != *" $esperado_status" ]] || [[ "$log" != *"$causa"* ]]; then
    echo "FALHA  monitor com upstream $nome: status '$status' (esperado $esperado_status), causa '$causa' no log de erro" >&2
    printf '%s\n' "$log" | tail -n 5 >&2
    exit 1
  fi
  echo "OK     monitor com upstream $nome: $esperado_status e a causa ($causa) no log de erro"
  sem_token_no_log "$nome" "$nome"
}
falha_upstream "$NAME-nginx-recusa" 3001 502 "Connection refused"
docker rm -f "$NAME-nginx-recusa" >/dev/null
falha_upstream "$NAME-nginx-prazo" 3000 504 "upstream timed out"
