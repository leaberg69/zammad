#!/bin/sh
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/
#
# Entrada do container zammad-nginx da Central de Atendimento Grupo LRI (docs/lri/PLANO.md, seção 2.9.2).
# Renderiza contrib/lri/deploy/nginx/ com as variáveis de ambiente, confere a configuração e inicia o Nginx.
# Qualquer variável ausente ou fora do formato interrompe a partida com a mensagem do motivo.
#
#   LRI_ZONE_KEY        segredo de zona (mesmo valor do Zammad), 32+ caracteres [A-Za-z0-9_-]
#   LRI_FQDN            endereço principal, ex.: suporte.lri.com.br
#   LRI_INTERNAL_HOST   nome interno da equipe, ex.: atendimento.lri.com.br
#   LRI_MW_HOST         nome público da Mean Well Brasil, ex.: suporte.meanwellbrasil.com.br
#   LRI_PUBLIC_HOSTS    nomes públicos separados por espaço
#   ZAMMAD_RAILSSERVER_HOST/PORT, ZAMMAD_WEBSOCKET_HOST/PORT, NGINX_CLIENT_MAX_BODY_SIZE (padrões da stack oficial)
#   LRI_NGINX_DRY_RUN=1 só renderiza (usado pelos testes)

set -eu

fail() {
  echo "nginx-entrypoint (Grupo LRI): $*" >&2
  exit 1
}

SRC_DIR=${LRI_NGINX_SRC:-$(dirname "$0")/nginx}
INC_DIR=${LRI_NGINX_INC_DIR:-/etc/nginx/lri}
SITE_FILE=${LRI_NGINX_SITE:-/etc/nginx/sites-enabled/default}

RAILS_UPSTREAM="${ZAMMAD_RAILSSERVER_HOST:-zammad-railsserver}:${ZAMMAD_RAILSSERVER_PORT:-3000}"
WEBSOCKET_UPSTREAM="${ZAMMAD_WEBSOCKET_HOST:-zammad-websocket}:${ZAMMAD_WEBSOCKET_PORT:-6042}"
MAX_BODY=${NGINX_CLIENT_MAX_BODY_SIZE:-50M}

check_host() {
  printf '%s' "$2" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' || fail "$1 ausente ou inválido: '$2'"
}

printf '%s' "${LRI_ZONE_KEY:-}" | grep -Eq '^[A-Za-z0-9_-]{32,}$' \
  || fail "LRI_ZONE_KEY ausente ou fora do formato (32+ caracteres A-Z a-z 0-9 _ -)"
check_host LRI_FQDN "${LRI_FQDN:-}"
check_host LRI_INTERNAL_HOST "${LRI_INTERNAL_HOST:-}"
check_host LRI_MW_HOST "${LRI_MW_HOST:-}"
[ -n "${LRI_PUBLIC_HOSTS:-}" ] || fail "LRI_PUBLIC_HOSTS ausente"
for host in $LRI_PUBLIC_HOSTS; do check_host LRI_PUBLIC_HOSTS "$host"; done
printf '%s' "$RAILS_UPSTREAM $WEBSOCKET_UPSTREAM" | grep -Eq '^[A-Za-z0-9.-]+:[0-9]+ [A-Za-z0-9.-]+:[0-9]+$' \
  || fail "upstreams inválidos: $RAILS_UPSTREAM $WEBSOCKET_UPSTREAM"
printf '%s' "$MAX_BODY" | grep -Eq '^[0-9]+[kKmMgG]?$' || fail "NGINX_CLIENT_MAX_BODY_SIZE inválido: $MAX_BODY"

# Para as expressões ancoradas do map de Origin: pontos escapados (os nomes já foram validados acima). A barra sai
# dobrada aqui porque o sed da renderização, abaixo, consome uma delas na substituição.
INTERNAL_HOST_RE=$(printf '%s' "$LRI_INTERNAL_HOST" | sed 's/\./\\\\./g')
MW_HOST_RE=$(printf '%s' "$LRI_MW_HOST" | sed 's/\./\\\\./g')

mkdir -p "$INC_DIR" "$(dirname "$SITE_FILE")"

sed -e "s#@RAILS_UPSTREAM@#${RAILS_UPSTREAM}#g" \
    -e "s#@WEBSOCKET_UPSTREAM@#${WEBSOCKET_UPSTREAM}#g" \
    -e "s#@FQDN@#${LRI_FQDN}#g" \
    -e "s#@INTERNAL_HOST_RE@#${INTERNAL_HOST_RE}#g" \
    -e "s#@MW_HOST_RE@#${MW_HOST_RE}#g" \
    -e "s#@INTERNAL_HOST@#${LRI_INTERNAL_HOST}#g" \
    -e "s#@MW_HOST@#${LRI_MW_HOST}#g" \
    -e "s#@PUBLIC_HOSTS@#${LRI_PUBLIC_HOSTS}#g" \
    -e "s#@MAX_BODY@#${MAX_BODY}#g" \
    "$SRC_DIR/lri-zones.conf.template" > "$SITE_FILE"

cp "$SRC_DIR/lri-zone-public.inc" "$INC_DIR/lri-zone-public.inc"
umask 077
sed -e "s#@LRI_ZONE_KEY@#${LRI_ZONE_KEY}#g" "$SRC_DIR/lri-zone-internal.inc" > "$INC_DIR/lri-zone-internal.inc"

if grep -q '@[A-Z_]*@' "$SITE_FILE" "$INC_DIR"/*.inc; then
  fail "marcador não substituído na configuração renderizada"
fi

[ "${LRI_NGINX_DRY_RUN:-0}" = "1" ] && exit 0

NAMESERVER=$(grep '^nameserver' --max-count 1 < /etc/resolv.conf | awk '{print $2}')
echo "resolver $NAMESERVER valid=5s;" > /etc/nginx/conf.d/resolver.conf

nginx -t || fail "nginx -t recusou a configuração renderizada"
echo "nginx-entrypoint (Grupo LRI): zonas pública (127.0.0.1:8081) e interna (127.0.0.1:8082) configuradas"
exec nginx -g 'daemon off;'
