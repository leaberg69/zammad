#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# subir-central.sh com um docker falso: ordem dos passos, portões e túnel fechado em qualquer falha.
# shellcheck disable=SC2016,SC2317 # conferências e funções auxiliares são avaliadas depois, por confere (eval)
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
if [ -n "${PENDURAR_EM:-}" ] && [[ "$*" == *"$PENDURAR_EM"* ]]; then sleep 10; fi
if [[ "$*" == *"20241/ready"* ]] && [ "${TUNNEL_READY:-true}" != true ]; then exit 7; fi
saude_padrao='{"status":"yellow","timed_out":false}'
case "$*" in
  "ps -a -q --filter "*) [ "${PS_FALHA:-0}" = 1 ] && exit 1; printf '%s' "${INIT_RESTANTE:-}" ;;
  *" ps -q --status running "*) printf '%s' "${APP_RODANDO:-}" ;;
  *"_cluster/health"*) printf '%s' "${ES_BODY-$saude_padrao}" ;;
  *" logs "*cloudflared*) printf '%s\n' "${TUNNEL_LOG-INF Registered tunnel connection connIndex=0}" ;;
  *" config --images "*) printf '%s\n' postgres:17.11-alpine redis:8.10.3-alpine memcached:1.6.45-alpine \
                            "${IMAGEM_CONFIG:-ghcr.io/leaberg69/zammad-lri:1.2.3}" "${IMAGEM_CONFIG_2:-ghcr.io/leaberg69/zammad-lri:1.2.3}" ;;
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
  (cd "$work" && env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 SUBIR_TENTATIVAS=3 "$@" \
    bash "$script" > "$work/saida" 2>&1)
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
confere 'zammad-init da imagem roda antes da aplicação' '[ "$(linha "name lri-zammad-init")" -lt "$(linha "zammad-railsserver zammad-websocket")" ]'
confere 'Elasticsearch sobe e é conferido antes do init' \
  'grep -q "zammad-elasticsearch$" "$work/log" && [ "$(linha "wait_for_status=yellow")" -lt "$(linha "name lri-zammad-init")" ]'
confere 'WebSocket e Nginx conferidos antes do túnel' \
  '[ "$(linha "127.0.0.1/6042")" -lt "$(linha "no-deps cloudflared")" ] && [ "$(linha "127.0.0.1:8081")" -lt "$(linha "no-deps cloudflared")" ]'
confere 'sucesso só com a conexão do túnel ativa (/ready)' \
  'grep -q "PORTÕES OK" "$work/saida" && grep -q "TÚNEL ABERTO" "$work/saida" && grep -q "exec -T zammad-nginx curl .*20241/ready" "$work/log"'

cenario 'sem ABRIR_TUNEL o túnel fica parado' 0
confere 'túnel não reaberto sem ABRIR_TUNEL' '! tunel_aberto'

for passo in 'run --rm --no-deps lri-config-check' 'name lri-zammad-init' '_cluster/health' \
             'zammad-railsserver curl' '--wait --wait-timeout 900' '127.0.0.1/6042' '127.0.0.1:8081'; do
  cenario "falha em '$passo'" 1 ABRIR_TUNEL=1 FALHAR_EM="$passo"
  confere "falha em '$passo' mantém o túnel fechado e diz por quê" \
    '! tunel_aberto && grep -q "PARAR:" "$work/saida" && grep -q "Estado do túnel: parado" "$work/saida"'
done

cenario 'zammad-init pendurado' 1 ABRIR_TUNEL=1 INIT_PRAZO=1 PENDURAR_EM='name lri-zammad-init'
confere 'prazo do init estoura, remoção confirmada e túnel fechado' \
  '! tunel_aberto && grep -q "foi encerrado e removido" "$work/saida" && grep -q "^rm -f lri-zammad-init-" "$work/log" && grep -q "^ps -a -q --filter name=^lri-zammad-init-" "$work/log"'

cenario 'zammad-init pendurado e a remoção não se confirma' 1 ABRIR_TUNEL=1 INIT_PRAZO=1 PENDURAR_EM='name lri-zammad-init' INIT_RESTANTE=abc123
confere 'não afirma encerramento sem confirmar' \
  '! tunel_aberto && grep -q "NÃO foi possível confirmar o encerramento" "$work/saida" && ! grep -q "foi encerrado e removido" "$work/saida"'

cenario 'zammad-init pendurado e a consulta ao Docker falha' 1 ABRIR_TUNEL=1 INIT_PRAZO=1 PENDURAR_EM='name lri-zammad-init' PS_FALHA=1
confere 'consulta que falha não confirma a remoção' \
  'grep -q "NÃO foi possível confirmar o encerramento" "$work/saida" && ! grep -q "foi encerrado e removido" "$work/saida"'

cenario 'caminho feliz (ordem da parada)' 0
confere 'aplicação parada e confirmada antes do init' \
  '[ "$(linha "stop zammad-railsserver")" -lt "$(linha "name lri-zammad-init")" ] && [ "$(linha "ps -q --status running")" -lt "$(linha "name lri-zammad-init")" ]'

cenario 'aplicação continua rodando depois do stop' 1 ABRIR_TUNEL=1 APP_RODANDO=abc123
confere 'sem parada confirmada não há migração nem túnel' \
  '! grep -q "name lri-zammad-init" "$work/log" && ! tunel_aberto && grep -q "ainda em execução" "$work/saida"'

cenario 'Nginx aceita a conexão e não responde' 1 ABRIR_TUNEL=1 PENDURAR_EM='127.0.0.1:8081' SUBIR_PRAZO_TENTATIVA=1 SUBIR_TENTATIVAS=2
confere 'verificação pendurada para por prazo, com o túnel fechado' '! tunel_aberto && grep -q "Nginx .* não respondeu depois de 2 tentativas" "$work/saida"'

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

cenario 'cloudflared conectou, perdeu a conexão e segue rodando' 1 ABRIR_TUNEL=1 TUNNEL_READY=false
confere 'log antigo de conexão com /ready falhando não vale como sucesso' \
  'grep -q "sem conexão ativa" "$work/saida" && ! grep -q "TÚNEL ABERTO" "$work/saida" && fechado_de_novo'

cenario 'cloudflared nunca conecta' 1 ABRIR_TUNEL=1 TUNNEL_LOG='INF Starting tunnel' TUNNEL_READY=false
confere 'sem conexão ativa não há sucesso e o túnel é fechado de novo' \
  'grep -q "sem conexão ativa" "$work/saida" && grep -q "Starting tunnel" "$work/saida" && fechado_de_novo'

# Interrupção durante a espera do /ready: o túnel recém-aberto tem de ser fechado.
: > "$work/log"
(cd "$work" && exec env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 SUBIR_TENTATIVAS=50 \
  SUBIR_PRAZO_TENTATIVA=1 PENDURAR_EM='20241/ready' ABRIR_TUNEL=1 bash "$script" > "$work/saida" 2>&1) &
pid=$!
for _ in $(seq 1 100); do grep -q '20241/ready' "$work/log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$pid"
wait "$pid"
codigo=$?
confere 'interrupção com o túnel aberto fecha o túnel e diz por quê' \
  '[ "$codigo" != 0 ] && fechado_de_novo && grep -q "execução interrompida" "$work/saida"'

cenario 'falha ao parar o túnel' 1 ABRIR_TUNEL=1 FALHAR_EM='stop cloudflared'
confere 'não afirma túnel parado sem ter parado' 'grep -q "pode continuar aberto" "$work/saida" && grep -q "não verificado" "$work/saida"'

cenario 'compose não renderiza (LRI_IMAGE_TAG ausente)' 1 ABRIR_TUNEL=1 FALHAR_EM='config --images'
confere 'nada além da leitura é chamado e o túnel fica como não verificado' \
  '[ "$(wc -l < "$work/log")" = 1 ] && grep -q "não verificado" "$work/saida"'

cenario 'imagem configurada fora do repositório do fork' 1 ABRIR_TUNEL=1 \
  IMAGEM_CONFIG=ghcr.io/zammad/zammad:7.2.0 IMAGEM_CONFIG_2=ghcr.io/zammad/zammad:7.2.0
confere 'imagem estranha recusada antes de parar algo' '[ "$(wc -l < "$work/log")" = 1 ] && grep -q "fora de ghcr.io/leaberg69/zammad-lri" "$work/saida"'

cenario 'duas tags do fork na mesma configuração' 1 ABRIR_TUNEL=1 IMAGEM_CONFIG_2=ghcr.io/leaberg69/zammad-lri:9.9.9
confere 'tags divergentes recusadas antes de parar algo' '[ "$(wc -l < "$work/log")" = 1 ] && grep -q "mais de uma tag" "$work/saida"'

# Interrupção durante o init: o container do init tem de ser encerrado e a remoção confirmada.
: > "$work/log"
(cd "$work" && exec env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 INIT_PRAZO=60 \
  PENDURAR_EM='name lri-zammad-init' ABRIR_TUNEL=1 bash "$script" > "$work/saida" 2>&1) &
pid=$!
for _ in $(seq 1 100); do grep -q 'name lri-zammad-init' "$work/log" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$pid"
wait "$pid"
codigo=$?
confere 'interrupção durante o init encerra o init e confirma' \
  '[ "$codigo" != 0 ] && grep -q "^rm -f lri-zammad-init-" "$work/log" && grep -q "execução interrompida" "$work/saida" && grep -q "foi encerrado e removido" "$work/saida" && ! tunel_aberto'

exit "$falhas"
