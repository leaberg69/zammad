# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Zona da requisição corrente, gravada pela guarda (Lri::ZoneGuard) para o código que não recebe o env do Rack, como
# Auth e os serviços de redefinição de senha. Zerada pelo executor do Rails ao fim de cada requisição.
class Lri::Current < ActiveSupport::CurrentAttributes
  attribute :zone
end
