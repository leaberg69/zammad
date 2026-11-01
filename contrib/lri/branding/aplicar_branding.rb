# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Aplica os dados de branding da ux-spec (docs/lri/esteira/branding/) a uma instância: nome do produto,
# organização, idioma e fuso padrão, logo da instância, cores da base de conhecimento e ordem das categorias
# de marca da KB.
#
# Uso, dentro do container do Zammad (homologação; produção só com OK do Leandro):
#   bundle exec rails runner contrib/lri/branding/aplicar_branding.rb
#
# O estado final é idempotente (cada execução regrava o logo com um timestamp novo). Cada passo imprime o que foi
# pedido e o que ficou. Saída: 0 = tudo aplicado; 2 = parcial (algum passo ficou pendente, com o motivo);
# 1 = falhou (com o motivo). Nada é pulado em silêncio.

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

# Ordem das categorias de primeiro nível (ux-spec v2, kb_publica.categorias).
KB_CATEGORY_ORDER = ['LRI', 'IRD.Net', 'Mean Well Brasil'].freeze

failures = []
pending  = []

step = lambda do |name, &block|
  block.call
rescue => e
  failures << "#{name}: #{e.class}: #{e.message}"
end

SETTINGS.each do |name, value|
  step.call("setting #{name}") do
    Setting.set(name, value)
    current = Setting.get(name)
    if current == value
      puts "ok   setting #{name} = #{value.inspect}"
    else
      failures << "setting #{name}: pedido #{value.inspect}, ficou #{current.inspect}"
    end
  end
end

step.call('product_logo') do
  if !LOGO_PATH.exist?
    failures << "product_logo: arquivo #{LOGO_PATH} não existe na imagem; rode contrib/lri/branding/gerar_logos.py e reconstrua"
    next
  end

  timestamp = Service::SystemAssets::ProductLogo.store(LOGO_PATH.read)
  if !timestamp
    failures << "product_logo: o Zammad recusou #{LOGO_PATH} (ProductLogo.store devolveu nil)"
    next
  end

  setting = Setting.lookup(name: 'product_logo')
  setting.state = timestamp
  setting.save!
  puts "ok   product_logo = #{LOGO_PATH.basename} (#{timestamp})"
end

step.call('base de conhecimento') do
  kbs = KnowledgeBase.all.to_a
  if kbs.empty?
    pending << 'base de conhecimento ainda não criada: cores e ordem das categorias não aplicadas (rode de novo depois de criá-la)'
    next
  end

  kbs.each do |kb|
    if kb.update(KB_COLORS)
      puts "ok   KB #{kb.id} cores #{KB_COLORS.values.join(', ')}"
    else
      failures << "KB #{kb.id}: #{kb.errors.full_messages.join('; ')}"
    end

    # A posição só vale com a ordenação manual (KnowledgeBase::Category.sorted_by_mode); em 'alphabetical' ou
    # 'last_update' a ordem pedida seria ignorada sem aviso.
    if kb.category_sorting_mode != 'manual'
      previous = kb.category_sorting_mode
      kb.update!(category_sorting_mode: 'manual')
      puts "info KB #{kb.id} modo de ordenação das categorias alterado de #{previous.inspect} para \"manual\""
    end

    roots = kb.categories.where(parent_id: nil).to_a
    by_title = roots.index_by { |cat| cat.translations.first&.title }
    missing = KB_CATEGORY_ORDER.reject { |title| by_title.key?(title) }
    missing.each { |title| pending << "KB #{kb.id}: categoria de primeiro nível #{title.inspect} não existe (crie no provisionamento)" }

    ordered = KB_CATEGORY_ORDER.select { |title| by_title.key?(title) } + (by_title.keys - KB_CATEGORY_ORDER)
    ordered.each_with_index { |title, index| by_title[title].update!(position: index) }

    # Confere a ordem que o site realmente vai mostrar, não só o que foi gravado.
    effective = kb.categories.where(parent_id: nil).sorted_by_mode(kb.reload.category_sorting_mode)
      .map { |cat| cat.translations.first&.title }
    expected = effective & KB_CATEGORY_ORDER
    if expected == KB_CATEGORY_ORDER.select { |title| by_title.key?(title) }
      puts "ok   KB #{kb.id} ordem efetiva das categorias: #{effective.join(', ')} (modo #{kb.category_sorting_mode})"
    else
      failures << "KB #{kb.id}: ordem pedida #{KB_CATEGORY_ORDER.join(', ')}, ordem efetiva #{effective.join(', ')} (modo #{kb.category_sorting_mode})"
    end
  end
end

if failures.any?
  warn "FALHOU (#{failures.size}):"
  failures.each { |f| warn "  - #{f}" }
  pending.each { |p| warn "  pendente: #{p}" }
  exit 1
end

if pending.any?
  warn "PARCIAL (#{pending.size} pendente(s)):"
  pending.each { |p| warn "  - #{p}" }
  exit 2
end

puts 'branding aplicado'
