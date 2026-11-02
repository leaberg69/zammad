#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Falhas simuladas sem rede: o timeout é trocado por uma função que reproduz cada resultado do bash.
set -u

# shellcheck source=contrib/lri/vps/checklist-leitura.sh
source "$(dirname "$0")/../checklist-leitura.sh"

falhas=0
igual() {
  if [ "$2" = "$3" ]; then
    printf 'ok    %s\n' "$1"
  else
    printf 'ERRO  %s\n  esperado: %s\n  veio:     %s\n' "$1" "$3" "$2"
    falhas=$((falhas + 1))
  fi
}

simular() {
  # shellcheck disable=SC2317 # chamada indiretamente por saida_tcp
  timeout() { [ -n "$SIMULA_ERRO" ] && printf '%b' "$SIMULA_ERRO" >&2; return "$SIMULA_CODIGO"; }
  SIMULA_CODIGO=$1 SIMULA_ERRO=$2
}

simular 0 ''
igual 'conexão aceita' "$(saida_tcp exemplo.test 443)" 'OK    exemplo.test:443'

simular 1 'bash: connect: Connection refused\nbash: line 1: /dev/tcp/exemplo.test/1: Connection refused\n'
igual 'recusa em duas linhas vira uma, com o código' "$(saida_tcp exemplo.test 1)" \
  'FALHA exemplo.test:1 (código 1: bash: connect: Connection refused bash: line 1: /dev/tcp/exemplo.test/1: Connection refused)'

simular 1 'bash: exemplo.invalid: Name or service not known\n'
igual 'falha de DNS mostra a mensagem do sistema' "$(saida_tcp exemplo.invalid 443)" \
  'FALHA exemplo.invalid:443 (código 1: bash: exemplo.invalid: Name or service not known)'

simular 124 ''
igual 'tempo esgotado' "$(saida_tcp exemplo.test 7844)" 'FALHA exemplo.test:7844 (código 124: sem resposta em 5 s)'

simular 1 ''
igual 'falha sem mensagem' "$(saida_tcp exemplo.test 9)" 'FALHA exemplo.test:9 (código 1: sem mensagem)'

simular 1 'erro\n'
igual 'a verificação seguinte roda depois da falha de rede' "$( { saida_tcp exemplo.test 1 > /dev/null; printf 'continuou'; } )" 'continuou'
unset -f timeout

igual 'comando que falha registra o código' "$(rodar false)" "$(printf '$ false\n(falhou com código 1: false)')"
igual 'o item seguinte roda depois da falha' "$( { rodar false > /dev/null; printf 'continuou'; } )" 'continuou'

exit "$falhas"
