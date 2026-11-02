# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Zona da requisição corrente, gravada pela guarda (Lri::ZoneGuard) para o código que não recebe o env do Rack, como
# Auth e os serviços de redefinição de senha.
#
# O valor pode virar nil no meio da requisição (o Zammad chama ActiveSupport::CurrentAttributes.clear_all em
# ApplicationModel::HasCache#cache_update) e é nil em jobs, console e tempo real. Todo código que o lê trata nil como
# "não é zona interna" (falha fechada), nunca como "não é zona pública".
class Lri::Current < ActiveSupport::CurrentAttributes
  attribute :zone
end
