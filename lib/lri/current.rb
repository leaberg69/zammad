# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Pode virar nil no meio da requisição (CurrentAttributes.clear_all no cache_update) e fora dela: nil nunca é zona
#   interna.
class Lri::Current < ActiveSupport::CurrentAttributes
  attribute :zone
end
