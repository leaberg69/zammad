#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# subir-central.sh com um docker falso: ordem dos passos, portões e túnel fechado em qualquer falha.
# shellcheck disable=SC2016,SC2034,SC2317 # conferências, variáveis e funções auxiliares são lidas por confere (eval)
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
if [ -n "${PENDURAR_EM:-}" ] && [[ "$*" == *"$PENDURAR_EM"* ]]; then
  # CRIACAO_TARDIA: ao receber TERM, o "daemon" ainda conclui a criação do container antes de o cliente sair.
  if [ "${CRIACAO_TARDIA:-0}" = 1 ]; then
    trap 'sleep 1; echo "criado-tarde" >> "$LOG"; exit 143' TERM
  fi
  sleep 10 & wait $!
fi
if [[ "$*" == *"20241/ready"* ]] && [ "${TUNNEL_READY:-true}" != true ]; then exit 7; fi
saude_padrao='{"status":"yellow","timed_out":false}'
ultimo="${!#}"
case "$*" in
  "image inspect -f {{.Id}} "*) echo "${IMAGEM_ID:-sha256:aaa}" ;;
  "inspect -f {{.Config.Image}} {{.Image}} "*)
    echo "${IMAGEM_FALSA:-ghcr.io/leaberg69/zammad-lri:1.2.3} ${CONTAINER_IMAGEM_ID:-sha256:aaa}" ;;
  "inspect -f {{.State.Running}} {{.RestartCount}} "*) echo "${FUNDO_ESTADO:-true 0}" ;;
  "inspect -f {{.State.Running}} "*) echo "${TUNNEL_RUNNING:-true}" ;;
  "ps -q --filter status=running --filter "*) printf '%s' "${INIT_ANTIGO:-}" ;;
  "ps -a -q --filter "*) [ "${PS_FALHA:-0}" = 1 ] && exit 1; printf '%s' "${INIT_RESTANTE:-}" ;;
  *" ps -q --status running "*) printf '%s' "${APP_RODANDO:-}" ;;
  *"_cluster/health"*) printf '%s' "${ES_BODY-$saude_padrao}" ;;
  *" logs "*cloudflared*) printf '%s\n' "${TUNNEL_LOG-INF Registered tunnel connection connIndex=0}" ;;
  *" config --images "*) printf '%s\n' postgres:17.11-alpine redis:8.10.3-alpine memcached:1.6.45-alpine \
                            "${IMAGEM_CONFIG:-ghcr.io/leaberg69/zammad-lri:1.2.3}" "${IMAGEM_CONFIG_2:-ghcr.io/leaberg69/zammad-lri:1.2.3}" ;;
  *" ps -q "* | *" ps -a -q "*) echo "id-$ultimo" ;;
esac
exit 0
FAKE
chmod +x "$work/bin/docker"

falhas=0
cenario() {
  local nome=$1 esperado_codigo=$2; shift 2
  : > "$work/log"
  (cd "$work" && env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 SUBIR_TENTATIVAS=3 SUBIR_ESTABILIZAR=0 "$@" \
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
confere 'imagem e ID lidos antes de tudo, e o túnel parado em seguida' \
  '[ "$(sed -n 1p "$work/log")" = "compose -f docker-compose.yml -f docker-compose.lri.yml config --images zammad-railsserver" ] && [ "$(sed -n 2p "$work/log")" = "image inspect -f {{.Id}} ghcr.io/leaberg69/zammad-lri:1.2.3" ] && [ "$(sed -n 3p "$work/log")" = "compose -f docker-compose.yml -f docker-compose.lri.yml stop cloudflared" ]'
confere 'túnel reaberto só depois dos portões' '[ "$(linha "zammad-railsserver curl")" -lt "$(linha "no-deps cloudflared")" ]'
confere 'zammad-init da imagem roda antes da aplicação' '[ "$(linha "name lri-zammad-init")" -lt "$(linha "zammad-railsserver zammad-websocket")" ]'
confere 'Elasticsearch sobe e é conferido antes do init' \
  'grep -q "zammad-elasticsearch$" "$work/log" && [ "$(linha "wait_for_status=yellow")" -lt "$(linha "name lri-zammad-init")" ]'
confere 'WebSocket e Nginx conferidos antes do túnel' \
  '[ "$(linha "127.0.0.1/6042")" -lt "$(linha "no-deps cloudflared")" ] && [ "$(linha "127.0.0.1:8081")" -lt "$(linha "no-deps cloudflared")" ]'
confere 'sucesso só com a conexão do túnel ativa (/ready)' \
  'grep -q "PORTÕES OK" "$work/saida" && grep -q "TÚNEL ABERTO" "$work/saida" && grep -q "exec -T zammad-nginx curl .*20241/ready" "$work/log"'

fundo_iniciado() { grep -q -- "--wait-timeout 900 zammad-scheduler zammad-backup" "$work/log"; }
confere 'processos de fundo só na liberação, depois dos portões e antes do túnel' \
  '[ "$(linha "127.0.0.1:8081")" -lt "$(linha "wait-timeout 900 zammad-scheduler")" ] && [ "$(linha "wait-timeout 900 zammad-scheduler")" -lt "$(linha "no-deps cloudflared")" ]'

cenario 'sem ABRIR_TUNEL o túnel fica parado' 0
confere 'túnel e processos de fundo não liberados sem ABRIR_TUNEL' '! tunel_aberto && ! fundo_iniciado'

cenario 'init anterior ainda rodando' 1 ABRIR_TUNEL=1 INIT_ANTIGO=velho123
confere 'init anterior impede a migração nova' '! grep -q "name lri-zammad-init" "$work/log" && grep -q "init ou reindexação em execução de antes" "$work/saida"'
confere 'init em reinício ou pausado também conta como ativo, e o serviço zammad-init é parado' \
  'grep -q "status=restarting --filter status=paused" "$work/log" && grep -q "stop .*zammad-backup zammad-init$" "$work/log"'

cenario 'scheduler cai durante a inicialização' 1 ABRIR_TUNEL=1 FUNDO_ESTADO='false 2'
confere 'processo de fundo instável impede o túnel e para os de fundo de novo' \
  '! tunel_aberto && grep -q "instável" "$work/saida" && grep -q "processos de fundo parados de novo" "$work/saida"'

cenario 'restauração com reindexação falhando' 1 ABRIR_TUNEL=1 REINDEXAR=1 FALHAR_EM='searchindex:rebuild'
confere 'reindexação que falha não libera processos de fundo nem túnel' '! fundo_iniciado && ! tunel_aberto'

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

cenario 'zammad-init falha com erro comum' 1 ABRIR_TUNEL=1 FALHAR_EM='name lri-zammad-init'
confere 'erro comum do init também encerra e confirma o container' \
  '! tunel_aberto && grep -q "^rm -f lri-zammad-init-" "$work/log" && grep -q "foi encerrado e removido" "$work/saida"'

cenario 'zammad-init falha e o container continua lá' 1 ABRIR_TUNEL=1 FALHAR_EM='name lri-zammad-init' INIT_RESTANTE=abc123
confere 'container remanescente vira aviso explícito' 'grep -q "NÃO foi possível confirmar o encerramento" "$work/saida"'

cenario 'zammad-init falha e o daemon não responde à consulta' 1 ABRIR_TUNEL=1 FALHAR_EM='name lri-zammad-init' PS_FALHA=1
confere 'consulta indisponível vira aviso explícito' 'grep -q "NÃO foi possível confirmar o encerramento" "$work/saida"'

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
confere 'imagem divergente mantém o túnel fechado' '! tunel_aberto && grep -q "esperado .ghcr.io/leaberg69/zammad-lri:1.2.3" "$work/saida"'

cenario 'mesma tag com conteúdo diferente' 1 ABRIR_TUNEL=1 CONTAINER_IMAGEM_ID=sha256:bbb
confere 'conteúdo divergente com a mesma tag mantém o túnel fechado' '! tunel_aberto && grep -q "mesmo conteúdo" "$work/saida"'

cenario 'imagem da tag ausente no servidor' 1 ABRIR_TUNEL=1 FALHAR_EM='image inspect'
confere 'sem a imagem local nada é parado' '! grep -q "stop cloudflared" "$work/log" && grep -q "rodar o pull do runbook" "$work/saida"'

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
confere 'falha depois da liberação para os processos de fundo de novo' \
  '[ "$(linha "stop zammad-scheduler zammad-backup")" -gt "$(linha "wait-timeout 900 zammad-scheduler")" ] && grep -q "processos de fundo parados de novo" "$work/saida"'

cenario 'cloudflared nunca conecta' 1 ABRIR_TUNEL=1 TUNNEL_LOG='INF Starting tunnel' TUNNEL_READY=false
confere 'sem conexão ativa não há sucesso e o túnel é fechado de novo' \
  'grep -q "sem conexão ativa" "$work/saida" && grep -q "Starting tunnel" "$work/saida" && fechado_de_novo'

# Roda o script em segundo plano, com o mesmo ambiente de cenario(), e manda o sinal $1 só depois de ver $2 no log.
#   Se o passo não for alcançado em 30 s, o cenário falha por si (não vale interromper outra fase).
interromper_em() {
  local sinal=$1 marca=$2; shift 2
  : > "$work/log"
  (cd "$work" && exec env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 SUBIR_ESTABILIZAR=0 \
    SUBIR_PRAZO_TENTATIVA=1 "$@" bash "$script" > "$work/saida" 2>&1) &
  local pid=$! visto=0
  for _ in $(seq 1 300); do
    if grep -q -- "$marca" "$work/log" 2>/dev/null; then visto=1; break; fi
    sleep 0.1
  done
  local inicio=$SECONDS
  kill -"$sinal" "$pid" 2>/dev/null
  wait "$pid"
  codigo=$?
  duracao=$((SECONDS - inicio))
  if [ "$visto" != 1 ]; then
    echo "ERRO  interrupção: o passo '$marca' não foi alcançado em 30 s"; cat "$work/saida"; falhas=$((falhas + 1))
  fi
}

for sinal in TERM HUP; do
  interromper_em "$sinal" '20241/ready' SUBIR_TENTATIVAS=50 PENDURAR_EM='20241/ready' ABRIR_TUNEL=1
  confere "$sinal com o túnel aberto fecha túnel e processos de fundo e diz por quê" \
    '[ "$codigo" != 0 ] && fechado_de_novo && grep -q "processos de fundo parados de novo" "$work/saida" && grep -q "execução interrompida" "$work/saida"'
done

# Outra execução segurando o lock: a segunda é recusada antes de tocar na stack.
( flock 9; sleep 5 ) 9> "$work/.subir-central.lock" &
lock_pid=$!
for _ in $(seq 1 50); do flock -n "$work/.subir-central.lock" true 2>/dev/null || break; sleep 0.1; done
cenario 'segunda execução simultânea' 1 ABRIR_TUNEL=1
confere 'segunda execução recusada sem chamar o docker' '[ ! -s "$work/log" ] && grep -q "outra execução" "$work/saida"'
kill "$lock_pid" 2>/dev/null
wait "$lock_pid" 2>/dev/null

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

# Interrupção durante o init e durante a reindexação: o container temporário é encerrado e a remoção confirmada.
for sinal in TERM HUP; do
  interromper_em "$sinal" 'name lri-zammad-init' INIT_PRAZO=60 PENDURAR_EM='name lri-zammad-init' ABRIR_TUNEL=1
  confere "$sinal durante o init encerra o init na hora e confirma" \
    '[ "$codigo" != 0 ] && [ "$duracao" -lt 5 ] && grep -q "^rm -f lri-zammad-init-" "$work/log" && grep -q "execução interrompida" "$work/saida" && grep -q "foi encerrado e removido" "$work/saida" && ! tunel_aberto'
done

interromper_em TERM 'name lri-zammad-init' INIT_PRAZO=60 PENDURAR_EM='name lri-zammad-init' CRIACAO_TARDIA=1 ABRIR_TUNEL=1
confere 'criação tardia do container acontece antes da remoção e da confirmação' \
  '[ "$(linha "criado-tarde")" -lt "$(linha "^rm -f lri-zammad-init-")" ] && grep -q "foi encerrado e removido" "$work/saida"'

interromper_em TERM 'name lri-zammad-reindex' REINDEXAR=1 REINDEX_PRAZO=60 PENDURAR_EM='name lri-zammad-reindex' ABRIR_TUNEL=1
confere 'interrupção durante a reindexação encerra o container na hora e confirma' \
  '[ "$codigo" != 0 ] && [ "$duracao" -lt 5 ] && grep -q "^rm -f lri-zammad-reindex-" "$work/log" && grep -q "foi encerrado e removido" "$work/saida" && ! fundo_iniciado'

cenario 'reindexação falha com o container ainda lá' 1 ABRIR_TUNEL=1 REINDEXAR=1 FALHAR_EM='name lri-zammad-reindex' INIT_RESTANTE=abc
confere 'reindexação remanescente vira aviso explícito' \
  'grep -q "NÃO foi possível confirmar o encerramento do container lri-zammad-reindex-" "$work/saida" && grep -q "apagando e recriando os índices" "$work/saida"'

exit "$falhas"
