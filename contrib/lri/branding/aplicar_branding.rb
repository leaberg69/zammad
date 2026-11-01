# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Aplica os dados de branding da ux-spec (docs/lri/esteira/branding/ux-spec-v1.yaml) a uma instância:
# nome do produto, organização, idioma e fuso padrão, logo da instância e cores da base de conhecimento.
#
# Uso, dentro do container do Zammad (homologação; produção só com OK do Leandro):
#   bundle exec rails runner contrib/lri/branding/aplicar_branding.rb
#
# É idempotente. Cada passo imprime o que foi pedido e o que ficou; qualquer passo que não se cumpre
# encerra com código 1 e diz o motivo (nada é pulado em silêncio).

LOGO_PATH = Rails.root.join('public/assets/lri/grupo-lri-logo.svg')

SETTINGS = {
  'product_name'     => 'Central de Atendimento Grupo LRI',
  'organization'     => 'Grupo LRI',
  'locale_default'   => 'pt-br',
  'timezone_default' => 'America/Sao_Paulo',
}.freeze

KB_COLORS = {
  color_highlight:   '#3d7a12',
  color_header:      '#f9fafb',
  color_header_link: '#3d7a12',
}.freeze

failures = []

SETTINGS.each do |name, value|
  Setting.set(name, value)
  current = Setting.get(name)
  if current == value
    puts "ok   setting #{name} = #{value.inspect}"
  else
    failures << "setting #{name}: pedido #{value.inspect}, ficou #{current.inspect}"
  end
end

if LOGO_PATH.exist?
  timestamp = Service::SystemAssets::ProductLogo.store(LOGO_PATH.read)
  if timestamp
    setting = Setting.lookup(name: 'product_logo')
    setting.state = timestamp
    setting.save!
    puts "ok   product_logo = #{LOGO_PATH.basename} (#{timestamp})"
  else
    failures << "product_logo: o Zammad recusou #{LOGO_PATH} (ProductLogo.store devolveu nil)"
  end
else
  failures << "product_logo: arquivo #{LOGO_PATH} não existe na imagem; rode contrib/lri/branding/gerar_logos.py e reconstrua"
end

kbs = KnowledgeBase.all.to_a
if kbs.empty?
  puts 'aviso nenhuma base de conhecimento criada ainda; cores da KB não aplicadas (rode de novo depois de criar a KB)'
else
  kbs.each do |kb|
    if kb.update(KB_COLORS)
      puts "ok   KB #{kb.id} cores #{KB_COLORS.values.join(', ')}"
    else
      failures << "KB #{kb.id}: #{kb.errors.full_messages.join('; ')}"
    end
  end
end

if failures.any?
  warn "FALHOU (#{failures.size}):"
  failures.each { |f| warn "  - #{f}" }
  exit 1
end

puts 'branding aplicado'
