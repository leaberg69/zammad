#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# subir-central.sh com um docker falso: ordem dos passos, portões e túnel fechado em qualquer falha.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329 # conferências, variáveis e funções auxiliares são lidas por confere (eval)
set -u

script="$(cd "$(dirname "$0")/.." && pwd)/subir-central.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# O docker falso registra cada chamada e falha no passo cujo texto contém $FALHAR_EM. As respostas do
# Elasticsearch, dos logs do cloudflared e do estado do container vêm de variáveis do cenário.
mkdir -p "$work/bin"
cat > "$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
# Não herda o lock do subir-central.sh (descritor 9): um sleep órfão do falso o seguraria para o cenário seguinte.
exec 9>&-
echo "$*" >> "$LOG"
if [ -n "${FALHAR_EM:-}" ] && [[ "$*" == *"$FALHAR_EM"* ]]; then
  # ERRO_LONGO: a causa vem no começo de um stderr grande, como num erro do daemon com detalhes.
  [ "${ERRO_LONGO:-0}" = 1 ] && printf 'causa-inicial-do-daemon %0400d\n' 0 >&2
  echo "falha simulada em: $FALHAR_EM" >&2; exit 1
fi
if [[ "$*" == *"validar_tunel_fase_a.rb"* ]] && [ -n "${TUNEL_INVALIDO:-}" ]; then echo "$TUNEL_INVALIDO" >&2; exit 1; fi
# AVISO_COMPOSE: ao listar o Elasticsearch, o compose escreve um aviso no stderr e responde normalmente no stdout.
if [ "${AVISO_COMPOSE:-0}" = 1 ] && [[ "$*" == *" ps -q zammad-elasticsearch" ]]; then
  echo 'WARN[0000] The "X" variable is not set. Defaulting to a blank string.' >&2
fi
if [ -n "${PENDURAR_EM:-}" ] && [[ "$*" == *"$PENDURAR_EM"* ]]; then
  # IGNORAR_TERM: cliente que não sai com o TERM do timeout (só com o KILL do --kill-after).
  [ "${IGNORAR_TERM:-0}" = 1 ] && trap '' TERM
  # CRIACAO_TARDIA: ao receber TERM, o "daemon" ainda conclui a criação do container antes de o cliente sair.
  if [ "${CRIACAO_TARDIA:-0}" = 1 ]; then
    trap 'sleep 1; echo "criado-tarde" >> "$LOG"; exit 143' TERM
  fi
  # Sem herdar a saída: um sleep órfão seguraria a substituição de comando do script até terminar.
  sleep "${PENDURAR_S:-10}" > /dev/null 2>&1 & wait $!
fi
if [[ "$*" == *"20241/ready"* ]] && [ "${TUNNEL_READY:-true}" != true ]; then exit 7; fi
# Elasticsearch subindo: as primeiras $ES_RECUSAS consultas de saúde encontram a porta 9200 fechada (curl 7), como
#   logo depois de o compose recriar o container. O estado do container muda para $ES_ESTADO_DEPOIS a partir da
#   segunda inspeção (reinício por falta de memória, por exemplo).
if [[ "$*" == *"_cluster/health"* ]]; then
  n=$(( $(cat "$LOG.es" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LOG.es"
  if [ "$n" -le "${ES_RECUSAS:-0}" ]; then echo "curl: (7) Failed to connect to 127.0.0.1 port 9200" >&2; exit 7; fi
fi
if [[ "$*" == "inspect -f {{.State.Status}} {{.RestartCount}} {{.State.OOMKilled}} "* ]]; then
  n=$(( $(cat "$LOG.es-estado" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LOG.es-estado"
  # ES_INSPECAO_LENTA: da segunda inspeção em diante, o daemon demora esses segundos para responder.
  [ "$n" -gt 1 ] && [ -n "${ES_INSPECAO_LENTA:-}" ] && { sleep "$ES_INSPECAO_LENTA" > /dev/null 2>&1 & wait $!; }
  if [ "$n" -le 1 ]; then echo "running 0 false"; else echo "${ES_ESTADO_DEPOIS:-running 0 false}"; fi
  exit 0
fi
saude_padrao='{"status":"yellow","timed_out":false}'
ultimo="${!#}"
case "$*" in
  "image inspect -f {{.Id}} "*) echo "${IMAGEM_ID:-sha256:aaa}" ;;
  "inspect -f {{range .Config.Env}}{{println .}}{{end}} "*)
    printf 'LRI_ZONE_GUARD=%s\nLRI_INTERNAL_URL=https://atendimento.example.com\nLRI_ACCESS_TEAM_DOMAIN=lriteste.cloudflareaccess.com\nLRI_ACCESS_AUD=aud-um,aud-dois\nES_JAVA_OPTS=-Xms1g -Xmx1g\n' \
      "${GUARDA:-enforce}" ;;
  "inspect -f {{.HostConfig.Memory}} "*) echo 2147483648 ;;
  # ES_LOG_STDERR: linha do log do container entregue pelo compose no stderr, com código 0.
  *" logs "*zammad-elasticsearch*) printf '%s\n' "${ES_LOG-INFO starting ...}"
    [ -n "${ES_LOG_STDERR:-}" ] && printf '%s\n' "$ES_LOG_STDERR" >&2 ;;
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
  : > "$work/log"; rm -f "$work/log.es" "$work/log.es-estado" "$work/.subir-central-erros.log"
  (cd "$work" && env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 SUBIR_TENTATIVAS=3 SUBIR_ESTABILIZAR=0 \
    SUBIR_ES_PRAZO=2 "$@" \
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

# O YAML do túnel é conferido pelo validar_tunel_fase_a.rb (com teste próprio); aqui, o que o script faz com o veredito.
cenario 'guarda desligada e o validador recusa o túnel' 1 ABRIR_TUNEL=1 GUARDA=off TUNEL_INVALIDO='regras além da do nome interno: "suporte.example.com"'
confere 'guarda off com túnel recusado não libera nada e diz por quê' \
  '! tunel_aberto && ! fundo_iniciado && grep -q "suporte.example.com" "$work/saida" && grep -q "validar_tunel_fase_a.rb /etc/lri-cloudflared/config.yml atendimento.example.com lriteste aud-um,aud-dois" "$work/log"'

cenario 'guarda desligada e o validador aceita (fase A)' 0 ABRIR_TUNEL=1 GUARDA=off
confere 'fase A libera com o túnel aprovado pelo validador' 'tunel_aberto && grep -q "TÚNEL ABERTO" "$work/saida"'

cenario 'guarda ligada não consulta o validador' 0 ABRIR_TUNEL=1 TUNEL_INVALIDO='não deveria ser chamado'
confere 'com a guarda ligada o túnel segue sem o validador' '! grep -q "validar_tunel_fase_a.rb" "$work/log" && tunel_aberto'

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
confere 'verificação pendurada para por prazo, com o túnel fechado e o motivo' \
  '! tunel_aberto && grep -q "Nginx .* não respondeu depois de 2 tentativas" "$work/saida" && grep -q "última: sem resposta em 1 s" "$work/saida"'

cenario 'WebSocket recusa a conexão' 1 ABRIR_TUNEL=1 FALHAR_EM='127.0.0.1/6042'
confere 'erro da verificação traz código e mensagem' 'grep -q "última: código 1: falha simulada em: 127.0.0.1/6042" "$work/saida"'

cenario 'Elasticsearch responde 200 com estado red' 1 ABRIR_TUNEL=1 ES_BODY='{"status":"red","timed_out":true}'
confere 'red recusado, com o estado na mensagem e túnel fechado' '! tunel_aberto && grep -q "\"status\":\"red\"" "$work/saida"'

# Primeira subida (go-live): o compose recria o Elasticsearch e o --wait não espera a JVM, porque a stack oficial
#   não tem healthcheck nele. As primeiras consultas encontram a porta 9200 fechada; a espera tem de continuar.
cenario 'Elasticsearch recém-criado, porta fechada nas primeiras consultas' 0 ABRIR_TUNEL=1 ES_RECUSAS=3
confere 'espera pelo Elasticsearch continua até ele responder, e só então o init' \
  '[ "$(grep -c "_cluster/health" "$work/log")" = 4 ] && [ "$(linha "_cluster/health")" -lt "$(linha "name lri-zammad-init")" ] && grep -q "TÚNEL ABERTO" "$work/saida"'

cenario 'Elasticsearch nunca abre a porta' 1 ABRIR_TUNEL=1 ES_RECUSAS=1000000 SUBIR_ES_PRAZO=1
confere 'prazo esgotado traz estado do container, última consulta, heap, limite e dica de memória' \
  '! tunel_aberto && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "não ficou em yellow/green (. s de espera, prazo 1 s): prazo esgotado" "$work/saida" && grep -q "estado=running reinícios=0 OOMKilled=false" "$work/saida" && grep -q "Failed to connect to 127.0.0.1 port 9200" "$work/saida" && grep -q "heap -Xms1g -Xmx1g" "$work/saida" && grep -q "limite do container 2048 MB" "$work/saida" && grep -q "INFO starting" "$work/saida" && grep -q "free -m" "$work/saida"'
confere 'cada consulta de saúde recusada e o diagnóstico final ficam no registro de erros' \
  'grep -q "consulta de saúde do Elasticsearch" "$work/.subir-central-erros.log" && grep -q "Failed to connect to 127.0.0.1 port 9200" "$work/.subir-central-erros.log" && grep -q "subir-central.sh: espera pelo Elasticsearch" "$work/.subir-central-erros.log" && grep -q "respostas e erros completos da espera em .subir-central-erros.log" "$work/saida"'

cenario 'log do Elasticsearch com a causa no stderr' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=1 ES_RECUSAS=1000000 \
  ES_LOG_STDERR='ERROR java.lang.OutOfMemoryError: Java heap space'
confere 'causa no stderr do log aparece no diagnóstico e no registro persistente' \
  'grep -q "Log: INFO starting ... ERROR java.lang.OutOfMemoryError: Java heap space" "$work/saida" && grep -q "OutOfMemoryError" "$work/.subir-central-erros.log"'

printf -v log_longo '%*s' 700 ''
log_longo="ERROR causa-no-comeco-do-log ${log_longo// /x}"
cenario 'log do Elasticsearch longo com a causa no começo' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=1 ES_RECUSAS=1000000 \
  ES_LOG="$log_longo"
confere 'log longo: corte declarado na mensagem e log inteiro, com a causa, no registro' \
  'grep -q "\[últimos 600 de [0-9]* caracteres; inteiro no registro\]" "$work/saida" && grep -q "causa-no-comeco-do-log" "$work/.subir-central-erros.log"'

cenario 'Elasticsearch se recupera, mas o registro de erros não pôde ser gravado' 0 ABRIR_TUNEL=1 ES_RECUSAS=1 \
  SUBIR_ERROS_LOG=/proc/registro-impossivel/erros.log
confere 'subida segue e avisa que as tentativas recusadas não ficaram registradas' \
  'grep -q "TÚNEL ABERTO" "$work/saida" && grep -q "AVISO: não foi possível gravar o registro de erros em /proc/registro-impossivel/erros.log" "$work/saida"'

cenario 'registro de erros indisponível' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=1 ES_RECUSAS=1000000 \
  SUBIR_ERROS_LOG=/proc/registro-impossivel/erros.log
confere 'sem conseguir gravar o registro, o diagnóstico diz isso e não afirma que gravou' \
  'grep -q "NÃO foi possível gravar o registro de erros em /proc/registro-impossivel/erros.log" "$work/saida" && ! grep -q "completos da espera em /proc" "$work/saida" && grep -q "Failed to connect to 127.0.0.1 port 9200" "$work/saida"'

cenario 'Elasticsearch morto por falta de memória durante a espera' 1 ABRIR_TUNEL=1 ES_RECUSAS=1000000 \
  SUBIR_ES_PRAZO=60 ES_ESTADO_DEPOIS='restarting 1 true'
confere 'reinício por falta de memória para na hora, sem esperar o prazo, e diz por quê' \
  '! tunel_aberto && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "OOMKilled=true" "$work/saida" && grep -q "reiniciou durante a espera" "$work/saida" && [ "$(grep -c "_cluster/health" "$work/log")" -lt 5 ]'

cenario 'Elasticsearch reinicia durante a consulta e a instância nova responde yellow' 1 ABRIR_TUNEL=1 \
  ES_ESTADO_DEPOIS='running 1 false'
confere 'resposta saudável de uma instância reiniciada não libera o init, e a resposta aparece no diagnóstico' \
  '! tunel_aberto && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "reiniciou durante a espera" "$work/saida" && grep -q "Última consulta de saúde: código 0: \"status\":\"yellow\", \"timed_out\":false;" "$work/saida"'

cenario 'compose escreve aviso no stderr ao listar o Elasticsearch' 0 ABRIR_TUNEL=1 AVISO_COMPOSE=1
confere 'aviso do compose no stderr não contamina o ID do container' \
  'grep -q "^inspect -f {{.State.Status}} {{.RestartCount}} {{.State.OOMKilled}} id-zammad-elasticsearch$" "$work/log" && grep -q "TÚNEL ABERTO" "$work/saida"'

inicio_docker=$SECONDS
cenario 'Docker não responde à inspeção do Elasticsearch' 1 ABRIR_TUNEL=1 SUBIR_PRAZO_TENTATIVA=1 \
  PENDURAR_EM='{{.State.Status}}'
duracao_docker=$((SECONDS - inicio_docker))
confere 'inspeção pendurada: o prazo vencido também vai para o registro de erros' \
  'grep -q "(código 124): docker inspect -f {{.State.Status}}" "$work/.subir-central-erros.log"'
confere 'inspeção pendurada para pelo prazo da chamada e diz por quê' \
  '[ "$duracao_docker" -lt 6 ] && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "não foi possível inspecionar o container (sem resposta do Docker em 1 s; completo em .subir-central-erros.log)" "$work/saida"'

cenario 'Docker falha na inspeção com stderr longo' 1 ABRIR_TUNEL=1 FALHAR_EM='{{.State.Status}}' ERRO_LONGO=1
confere 'stderr longo: corte declarado na mensagem e texto completo no registro de erros' \
  '! grep -q "name lri-zammad-init" "$work/log" && grep -q "\[stderr cortado: [0-9]* caracteres, mostrados os 300 finais; completo em .subir-central-erros.log\]" "$work/saida" && grep -q "causa-inicial-do-daemon" "$work/.subir-central-erros.log" && grep -q "falha simulada em" "$work/.subir-central-erros.log"'

inicio_ps=$SECONDS
cenario 'Docker não responde ao localizar o Elasticsearch' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=1 SUBIR_PRAZO_TENTATIVA=60 \
  PENDURAR_EM=' ps -q zammad-elasticsearch'
duracao_ps=$((SECONDS - inicio_ps))
confere 'localização pendurada respeita o prazo total, diz por quê e não roda o init' \
  '[ "$duracao_ps" -lt 6 ] && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "não foi possível localizar o zammad-elasticsearch: sem resposta do Docker em 1 s" "$work/saida"'

inicio_diag=$SECONDS
cenario 'Docker não entrega o log no diagnóstico' 1 ABRIR_TUNEL=1 SUBIR_PRAZO_TENTATIVA=1 SUBIR_ES_PRAZO=1 \
  ES_RECUSAS=1000000 PENDURAR_EM='logs --tail 5 zammad-elasticsearch'
duracao_diag=$((SECONDS - inicio_diag))
confere 'diagnóstico pendurado não esconde a falha' \
  '[ "$duracao_diag" -lt 6 ] && grep -q "PARAR: Elasticsearch não ficou em yellow/green" "$work/saida" && grep -q "Log: sem resposta do Docker em 1 s" "$work/saida"'

# Consulta que pendura (conexão aceita sem resposta) enquanto o container reinicia: a janela da tentativa corta a
#   consulta e a reinspeção pega o reinício, sem esperar o prazo total.
inicio_janela=$SECONDS
cenario 'consulta pendurada enquanto o Elasticsearch reinicia' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=60 \
  SUBIR_PRAZO_TENTATIVA=1 PENDURAR_EM='_cluster/health' ES_ESTADO_DEPOIS='restarting 1 true'
duracao_janela=$((SECONDS - inicio_janela))
confere 'janela por tentativa corta a consulta e o reinício para a espera' \
  '[ "$duracao_janela" -lt 8 ] && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "reiniciou durante a espera" "$work/saida" && grep -q "sem resposta em 2 s" "$work/saida"'

# Resposta saudável na hora, mas a inspeção que confirma o container demora além do prazo total.
cenario 'inspeção final lenta depois da resposta saudável' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=1 SUBIR_PRAZO_TENTATIVA=5 \
  ES_INSPECAO_LENTA=3
confere 'inspeção final além do prazo não libera o init' \
  '! grep -q "name lri-zammad-init" "$work/log" && ! grep -q "Elasticsearch pronto" "$work/saida" && grep -q "PARAR: Elasticsearch" "$work/saida" && grep -q "Última consulta de saúde: código 0: \"status\":\"yellow\"" "$work/saida"'

# Cliente que ignora o TERM: o --kill-after mata e a espera segue, sem prender o script.
inicio_term=$SECONDS
cenario 'cliente Docker ignora o TERM numa consulta pendurada' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=60 \
  SUBIR_PRAZO_TENTATIVA=1 PENDURAR_EM='_cluster/health' PENDURAR_S=30 IGNORAR_TERM=1 ES_ESTADO_DEPOIS='restarting 1 true'
duracao_term=$((SECONDS - inicio_term))
confere 'TERM ignorado não prende a espera: o KILL encerra e o reinício é detectado' \
  '[ "$duracao_term" -lt 12 ] && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "reiniciou durante a espera" "$work/saida"'

# Zero à esquerda: o Bash leria 08 como octal (erro de aritmética) e 010 como 8; 0 desligaria o timeout.
for prazo in 5m 08 010 00 0 -1 100000; do
  cenario "prazo do Elasticsearch inválido ($prazo)" 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO="$prazo"
  confere "prazo $prazo recusado antes de chamar o docker" \
    '[ ! -s "$work/log" ] && grep -q "SUBIR_ES_PRAZO inválido" "$work/saida"'
done
for prazo in 0 -1 1s 0.5 08; do
  cenario "prazo por tentativa inválido ($prazo)" 1 ABRIR_TUNEL=1 SUBIR_PRAZO_TENTATIVA="$prazo"
  confere "prazo por tentativa $prazo recusado antes de chamar o docker" \
    '[ ! -s "$work/log" ] && grep -q "SUBIR_PRAZO_TENTATIVA inválido" "$work/saida"'
done
# O intervalo entra na espera pelo Elasticsearch (com a primeira consulta recusada, ele seria usado).
for espera in 0.5 08 -1 2s; do
  cenario "intervalo inválido ($espera)" 1 ABRIR_TUNEL=1 SUBIR_ESPERA="$espera" ES_RECUSAS=1
  confere "intervalo $espera recusado antes de chamar o docker" \
    '[ ! -s "$work/log" ] && grep -q "SUBIR_ESPERA inválido" "$work/saida"'
done

# A consulta pendura e responderia yellow depois do prazo: o prazo total corta a consulta e nada segue.
inicio_lento=$SECONDS
cenario 'consulta de saúde que só responderia depois do prazo' 1 ABRIR_TUNEL=1 SUBIR_ES_PRAZO=2 PENDURAR_EM='_cluster/health'
duracao_lenta=$((SECONDS - inicio_lento))
confere 'prazo total vale também para a consulta em andamento' \
  '[ "$duracao_lenta" -lt 6 ] && ! grep -q "name lri-zammad-init" "$work/log" && grep -q "prazo esgotado" "$work/saida" && grep -q "sem resposta em" "$work/saida"'

# Resposta real do _cluster/health tem mais de 300 caracteres; status e timed_out ficam no começo.
saude_grande='{"cluster_name":"docker-cluster","status":"red","timed_out":true,"number_of_nodes":1,"number_of_data_nodes":1,'
saude_grande+='"active_primary_shards":0,"active_shards":0,"relocating_shards":0,"initializing_shards":3,'
saude_grande+='"unassigned_shards":7,"unassigned_primary_shards":3,"delayed_unassigned_shards":0,"number_of_pending_tasks":2,'
saude_grande+='"number_of_in_flight_fetch":0,"task_max_waiting_in_queue_millis":1200,"active_shards_percent_as_number":0.0}'
cenario 'Elasticsearch red com a resposta completa do _cluster/health' 1 ABRIR_TUNEL=1 ES_BODY="$saude_grande"
confere 'status e timed_out aparecem mesmo com a resposta cortada, e o corte é declarado' \
  '! grep -q "name lri-zammad-init" "$work/log" && grep -q "código 0: \"status\":\"red\", \"timed_out\":true;" "$work/saida" && grep -q "\[cortada: [0-9]* caracteres, mostrados os 300 primeiros\]" "$work/saida"'

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
  : > "$work/log"; rm -f "$work/log.es" "$work/log.es-estado" "$work/.subir-central-erros.log"
  (cd "$work" && exec env PATH="$work/bin:$PATH" LOG="$work/log" SUBIR_ESPERA=0 SUBIR_ESTABILIZAR=0 \
    SUBIR_PRAZO_TENTATIVA=1 SUBIR_ES_PRAZO=2 "$@" bash "$script" > "$work/saida" 2>&1) &
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
