# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Provisiona a central conforme docs/lri/PLANO.md (Lri::Provisioning). Pode rodar quantas vezes for preciso.
# Uso: bundle exec rails runner contrib/lri/provisionamento/provisionar.rb
#      DRY_RUN=1 bundle exec rails runner contrib/lri/provisionamento/provisionar.rb   (só mostra o que mudaria)
# Em produção, só com OK de Leandro, e primeiro com DRY_RUN=1.

dry_run      = ENV['DRY_RUN'].present?
provisioning = Lri::Provisioning.apply!(dry_run:)
provisioning.results.each { |result| puts result }

if provisioning.conflicts?
  warn 'Nada foi gravado: resolva os conflitos acima (registros com o mesmo nome em outra caixa) e rode de novo.'
  exit 1
end

if dry_run
  puts 'Simulação: nada foi gravado.'
elsif provisioning.changed?
  puts 'Provisionamento aplicado.'
else
  puts 'Nada a mudar: a central já está provisionada.'
end
