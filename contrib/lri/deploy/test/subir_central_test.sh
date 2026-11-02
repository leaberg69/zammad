#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# subir-central.sh com um docker falso: ordem dos passos, portões e túnel fechado em qualquer falha.
# shellcheck disable=SC2016 # as conferências são avaliadas depois, por confere (eval)
set -u

script="$(cd "$(dirname "$0")/.." && pwd)/subir-central.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# O docker falso registra cada chamada e falha no passo cujo texto contém $FALHAR_EM. As respostas do
# Elasticsearch, dos logs do cloudflared e do estado do container vêm de variáveis do cenário.
mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$LOG"
if [ -n "${FALHAR_EM:-}" ] && [[ "$*" == *"$FALHAR_EM"* ]]; then exit 1; fi
saude_padrao='{"status":"yellow","timed_out":false}'
case "$*" in
  *"_cluster/health"*) printf '%s' "${ES_BODY-$saude_padrao}" ;;
  *" logs "*cloudflared*) printf '%s\n' "${TUNNEL_LOG-INF Registered tunnel connection connIndex=0}" ;;
  *" config --images "*) echo "${IMAGEM_CONFIG:-ghcr.io/leaberg69/zammad-lri:1.2.3}" ;;
  *" ps -q "* | *" ps -a -q "*) echo "id-${*##* }" ;;
  "inspect -f {{.Config.Image}} "*) echo "${IMAGEM_FALSA:-ghcr.io/leaberg69/zammad-lri:1.2.3}" ;;
  "inspect -f {{.State.Running}} "*) echo "${TUNNEL_RUNNING:-true}" ;;
esac
exit 0
FAKE
chmod +x "$work/bin/docker"

falhas=0
cenario() {
  local nome=$1 esperado_codigo=$2; shift 2
  : > "$work/log"
  (cd "$work" && env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 "$@" bash "$script" > "$work/saida" 2>&1)
  local codigo=$?
  if [ "$codigo" != "$esperado_codigo" ]; then
    echo "ERRO  $nome: código $codigo, esperado $esperado_codigo"; cat "$work/saida"; falhas=$((falhas + 1))
  fi
}
linha() { grep -n -- "$1" "$work/log" | tail -n1 | cut -d: -f1; }
tunel_aberto() { grep -q -- 'up -d --force-recreate --no-deps cloudflared' "$work/log"; }
confere() { if eval "$2"; then echo "ok    $1"; else echo "ERRO  $1"; cat "$work/saida" "$work/log"; falhas=$((falhas + 1)); fi; }

cenario 'caminho feliz com ABRIR_TUNEL=1' 0 ABRIR_TUNEL=1
confere 'imagem lida do compose e túnel parado antes de tudo' \
  '[ "$(sed -n 1p "$work/log")" = "compose -f docker-compose.yml -f docker-compose.lri.yml config --images zammad-railsserver" ] && [ "$(sed -n 2p "$work/log")" = "compose -f docker-compose.yml -f docker-compose.lri.yml stop cloudflared" ]'
confere 'túnel reaberto só depois dos portões' '[ "$(linha "zammad-railsserver curl")" -lt "$(linha "no-deps cloudflared")" ]'
confere 'zammad-init da imagem roda antes da aplicação' '[ "$(linha "run --rm --no-deps zammad-init")" -lt "$(linha "zammad-railsserver zammad-websocket")" ]'
confere 'Elasticsearch sobe e o estado é conferido' 'grep -q "zammad-elasticsearch$" "$work/log" && grep -q "wait_for_status=yellow" "$work/log"'
confere 'sucesso só com a conexão do túnel registrada' 'grep -q "PORTÕES OK" "$work/saida" && grep -q "TÚNEL ABERTO" "$work/saida"'

cenario 'sem ABRIR_TUNEL o túnel fica parado' 0
confere 'túnel não reaberto sem ABRIR_TUNEL' '! tunel_aberto'

for passo in 'run --rm --no-deps lri-config-check' 'run --rm --no-deps zammad-init' '_cluster/health' \
             'zammad-railsserver curl' '--wait --wait-timeout 900'; do
  cenario "falha em '$passo'" 1 ABRIR_TUNEL=1 FALHAR_EM="$passo"
  confere "falha em '$passo' mantém o túnel fechado e diz por quê" \
    '! tunel_aberto && grep -q "PARAR:" "$work/saida" && grep -q "Estado do túnel: parado" "$work/saida"'
done

cenario 'Elasticsearch responde 200 com estado red' 1 ABRIR_TUNEL=1 ES_BODY='{"status":"red","timed_out":true}'
confere 'red recusado, com o estado na mensagem e túnel fechado' '! tunel_aberto && grep -q "\"status\":\"red\"" "$work/saida"'

cenario 'imagem diferente da tag do .env' 1 ABRIR_TUNEL=1 IMAGEM_FALSA=ghcr.io/leaberg69/zammad-lri:0.9.0
confere 'imagem divergente mantém o túnel fechado' '! tunel_aberto && grep -q "esperado ghcr.io/leaberg69/zammad-lri:1.2.3" "$work/saida"'

cenario 'REINDEXAR=1 reconstrói o índice antes do túnel' 0 ABRIR_TUNEL=1 REINDEXAR=1
confere 'reindexação antes de reabrir' '[ "$(linha "searchindex:rebuild")" -lt "$(linha "no-deps cloudflared")" ]'

fechado_de_novo() { [ "$(linha "stop cloudflared")" -gt "$(linha "no-deps cloudflared")" ] && grep -q "parado de novo" "$work/saida"; }

cenario 'cloudflared cai logo depois de iniciar' 1 ABRIR_TUNEL=1 TUNNEL_LOG='ERR token inválido' TUNNEL_RUNNING=false
confere 'queda do túnel vira falha com o motivo e o túnel é fechado de novo' \
  'grep -q "não está em execução" "$work/saida" && grep -q "token inválido" "$work/saida" && fechado_de_novo'

cenario 'cloudflared conecta e cai' 1 ABRIR_TUNEL=1 TUNNEL_RUNNING=false
confere 'registro antigo de conexão não vale com o container parado' '! grep -q "TÚNEL ABERTO" "$work/saida" && fechado_de_novo'

cenario 'cloudflared nunca registra conexão' 1 ABRIR_TUNEL=1 TUNNEL_LOG='INF Starting tunnel'
confere 'sem conexão registrada não há sucesso e o túnel é fechado de novo' \
  'grep -q "sem conexão registrada" "$work/saida" && ! grep -q "TÚNEL ABERTO" "$work/saida" && fechado_de_novo'

cenario 'falha ao parar o túnel' 1 ABRIR_TUNEL=1 FALHAR_EM='stop cloudflared'
confere 'não afirma túnel parado sem ter parado' 'grep -q "pode continuar aberto" "$work/saida" && grep -q "não verificado" "$work/saida"'

cenario 'compose não renderiza (LRI_IMAGE_TAG ausente)' 1 ABRIR_TUNEL=1 FALHAR_EM='config --images'
confere 'nada além da leitura é chamado e o túnel fica como não verificado' \
  '[ "$(wc -l < "$work/log")" = 1 ] && grep -q "não verificado" "$work/saida"'

cenario 'imagem configurada fora do repositório do fork' 1 ABRIR_TUNEL=1 IMAGEM_CONFIG=ghcr.io/zammad/zammad:7.2.0
confere 'imagem estranha recusada antes de parar algo' '[ "$(wc -l < "$work/log")" = 1 ] && grep -q "fora de ghcr.io/leaberg69/zammad-lri" "$work/saida"'

exit "$falhas"
