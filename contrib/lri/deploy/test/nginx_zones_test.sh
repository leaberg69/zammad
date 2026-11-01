#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/
#
# Teste do Nginx das zonas: renderiza contrib/lri/deploy/nginx com o nginx-entrypoint.sh num container nginx, liga
# um upstream de eco no mesmo namespace de rede e confere cabeçalhos, Origin, redirecionamentos e bloqueios.
# Uso: contrib/lri/deploy/test/nginx_zones_test.sh   (precisa de Docker)

set -euo pipefail
export MSYS_NO_PATHCONV=1 # Git Bash no Windows: não converter caminhos dos volumes

DEPLOY=$(cd "$(dirname "$0")/.." && (pwd -W 2>/dev/null || pwd))
NAME="lri-nginx-test-$$"
KEY="chave-de-teste-0123456789abcdefghijkl"
NGINX_IMAGE=${NGINX_IMAGE:-nginx:1.27-alpine}
PYTHON_IMAGE=${PYTHON_IMAGE:-python:3.12-alpine}

cleanup() { docker rm -f "$NAME-echo" "$NAME-nginx" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME-echo" -v "$DEPLOY:/deploy:ro" "$PYTHON_IMAGE" python /deploy/test/echo_upstream.py >/dev/null

docker run -d --name "$NAME-nginx" --network "container:$NAME-echo" \
  -v "$DEPLOY:/opt/zammad/contrib/lri/deploy:ro" \
  -e LRI_ZONE_KEY="$KEY" \
  -e LRI_FQDN=suporte.lri.com.br \
  -e LRI_INTERNAL_HOST=atendimento.lri.com.br \
  -e LRI_MW_HOST=suporte.meanwellbrasil.com.br \
  -e LRI_PUBLIC_HOSTS="suporte.lri.com.br suporte.meanwellbrasil.com.br suporte.ird.net.br" \
  -e ZAMMAD_RAILSSERVER_HOST=127.0.0.1 -e ZAMMAD_WEBSOCKET_HOST=127.0.0.1 \
  -e LRI_NGINX_DRY_RUN=1 -e LRI_NGINX_SITE=/etc/nginx/conf.d/default.conf \
  "$NGINX_IMAGE" sh -c '/opt/zammad/contrib/lri/deploy/nginx-entrypoint.sh && nginx -t && exec nginx -g "daemon off;"' >/dev/null

for _ in $(seq 1 20); do
  if docker exec "$NAME-nginx" sh -c 'nc -z 127.0.0.1 8081 && nc -z 127.0.0.1 8082 && nc -z 127.0.0.1 3000' 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! docker exec "$NAME-nginx" nc -z 127.0.0.1 8082 2>/dev/null; then
  echo "Nginx não subiu; log:" >&2
  docker logs "$NAME-nginx" >&2
  exit 1
fi

docker run --rm --network "container:$NAME-echo" -v "$DEPLOY:/deploy:ro" "$PYTHON_IMAGE" python /deploy/test/check_nginx_zones.py "$KEY"
