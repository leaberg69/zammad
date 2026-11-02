#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# subir-central.sh com um docker falso: ordem dos passos e túnel fechado em qualquer falha.
# shellcheck disable=SC2016 # as conferências são avaliadas depois, por confere (eval)
set -u

script="$(cd "$(dirname "$0")/.." && pwd)/subir-central.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# O docker falso registra cada chamada e falha no passo cujo texto contém $FALHAR_EM.
mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$LOG"
if [ -n "${FALHAR_EM:-}" ] && [[ "$*" == *"$FALHAR_EM"* ]]; then exit 1; fi
case "$*" in
  *" ps -q "*) echo "id-${*##* }" ;;
  "inspect -f {{.Config.Image}} "*) echo "${IMAGEM_FALSA:-ghcr.io/leaberg69/zammad-lri:1.2.3}" ;;
esac
exit 0
FAKE
chmod +x "$work/bin/docker"

falhas=0
cenario() {
  local nome=$1 esperado_codigo=$2; shift 2
  : > "$work/log"
  (cd "$work" && env PATH="$work/bin:$PATH" LOG="$work/log" "$@" bash "$script" > "$work/saida" 2>&1)
  local codigo=$?
  if [ "$codigo" != "$esperado_codigo" ]; then
    echo "ERRO  $nome: código $codigo, esperado $esperado_codigo"; cat "$work/saida"; falhas=$((falhas + 1))
  fi
}
tunel_aberto() { grep -q 'up -d --force-recreate --no-deps cloudflared' "$work/log"; }
confere() { if eval "$2"; then echo "ok    $1"; else echo "ERRO  $1"; cat "$work/log"; falhas=$((falhas + 1)); fi; }

printf 'LRI_IMAGE_TAG=1.2.3\n' > "$work/.env"

cenario 'caminho feliz com ABRIR_TUNEL=1' 0 ABRIR_TUNEL=1
confere 'túnel parado primeiro e reaberto por último' \
  '[ "$(head -n1 "$work/log")" = "compose -f docker-compose.yml -f docker-compose.lri.yml stop cloudflared" ] && tail -n1 "$work/log" | grep -q "cloudflared$"'
confere 'zammad-init da imagem roda antes da aplicação' \
  '[ "$(grep -n "run --rm --no-deps zammad-init" "$work/log" | cut -d: -f1)" -lt "$(grep -n "zammad-railsserver zammad-websocket" "$work/log" | cut -d: -f1)" ]'
confere 'Elasticsearch sobe e é conferido' 'grep -q "zammad-elasticsearch$" "$work/log" && grep -q "exec -T zammad-elasticsearch curl" "$work/log"'
confere 'PORTÕES OK na saída' 'grep -q "PORTÕES OK" "$work/saida"'

cenario 'sem ABRIR_TUNEL o túnel fica parado' 0
confere 'túnel não reaberto sem ABRIR_TUNEL' '! tunel_aberto'

for passo in 'run --rm --no-deps lri-config-check' 'run --rm --no-deps zammad-init' 'zammad-elasticsearch curl' \
             'zammad-railsserver curl' '--wait --wait-timeout 900'; do
  cenario "falha em '$passo'" 1 ABRIR_TUNEL=1 FALHAR_EM="$passo"
  confere "falha em '$passo' mantém o túnel fechado e diz por quê" '! tunel_aberto && grep -q "PARAR:" "$work/saida"'
done

cenario 'imagem diferente da tag do .env' 1 ABRIR_TUNEL=1 IMAGEM_FALSA=ghcr.io/leaberg69/zammad-lri:0.9.0
confere 'imagem divergente mantém o túnel fechado' '! tunel_aberto && grep -q "esperado ghcr.io/leaberg69/zammad-lri:1.2.3" "$work/saida"'

cenario 'REINDEXAR=1 reconstrói o índice antes do túnel' 0 ABRIR_TUNEL=1 REINDEXAR=1
confere 'reindexação antes de reabrir' \
  '[ "$(grep -n "searchindex:rebuild" "$work/log" | cut -d: -f1)" -lt "$(grep -n "cloudflared$" "$work/log" | tail -n1 | cut -d: -f1)" ]'

printf 'OUTRA=1\n' > "$work/.env"
cenario 'sem LRI_IMAGE_TAG no .env' 1 ABRIR_TUNEL=1
confere 'sem tag nada é chamado' '[ ! -s "$work/log" ]'

exit "$falhas"
