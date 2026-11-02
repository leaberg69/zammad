#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Falhas simuladas: cada causa tem de aparecer na saída, e a verificação seguinte tem de rodar.
set -u

# shellcheck source=contrib/lri/vps/checklist-leitura.sh
source "$(dirname "$0")/../checklist-leitura.sh"

falhas=0
confere() {
  if printf '%s' "$2" | grep -qE "$3"; then
    printf 'ok    %s\n' "$1"
  else
    printf 'ERRO  %s: esperado /%s/, veio:\n%s\n' "$1" "$3" "$2"
    falhas=$((falhas + 1))
  fi
}

saida=$( { rodar false; rodar true; printf 'continuou\n'; } )
confere 'comando que falha registra o código' "$saida" '\(falhou com código 1: false\)'
confere 'o item seguinte roda depois da falha' "$saida" 'continuou'

saida=$(saida_tcp 127.0.0.1 1)
confere 'conexão recusada traz código e mensagem' "$saida" '^FALHA 127\.0\.0\.1:1 \(código [0-9]+: .+\)$'

saida=$(saida_tcp host-inexistente.invalid 443)
confere 'falha de DNS traz código e mensagem' "$saida" '^FALHA host-inexistente\.invalid:443 \(código [0-9]+: .+\)$'

saida=$( { saida_tcp 127.0.0.1 1; printf 'continuou\n'; } )
confere 'a verificação seguinte roda depois da falha de rede' "$saida" 'continuou'

exit "$falhas"
