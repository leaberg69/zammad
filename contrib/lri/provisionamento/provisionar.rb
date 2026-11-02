# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Provisiona a central conforme docs/lri/PLANO.md (Lri::Provisioning). Pode rodar quantas vezes for preciso.
# Uso: bundle exec rails runner contrib/lri/provisionamento/provisionar.rb
# Em produção, só com OK de Leandro.

provisioning = Lri::Provisioning.apply!
provisioning.results.each { |result| puts result }
puts provisioning.changed? ? 'Provisionamento aplicado.' : 'Nada a mudar: a central já está provisionada.'
