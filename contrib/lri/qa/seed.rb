# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Dados de teste para as capturas do UX-B (contrib/lri/qa/capture.py). Só para instância LOCAL; nunca produção.
# Uso: bundle exec rails runner contrib/lri/qa/seed.rb (depois do wizard.json aplicado por AutoWizard.setup).
# O wizard.json de QA cria usuários com senha de teste conhecida; ele nunca vira auto_wizard.json fora da máquina
# local (ver docs/lri/VPS-CHECKLIST.md).

fqdn = Setting.get('fqdn').to_s
if !fqdn.match?(%r{\A(localhost|127\.0\.0\.1)(:\d+)?\z})
  abort "seed.rb recusado: fqdn #{fqdn.inspect} não é local. Estes dados de teste são só para instância local."
end

UserInfo.current_user_id = 1
priority = Ticket::Priority.find_by(name: '2 normal')
web      = Ticket::Article::Type.find_by(name: 'web')
note     = Ticket::Article::Type.find_by(name: 'note')
customer_sender = Ticket::Article::Sender.find_by(name: 'Customer')
agent_sender    = Ticket::Article::Sender.find_by(name: 'Agent')

cliente = User.find_by(login: 'cliente1@cliente.example.com')
agente  = User.find_by(login: 'agente@lri.example')

[
  ['Fonte HRP-150-24 não liga', 'LRI', 'open'],
  ['Switch IRD com porta SFP sem link', 'IRD.Net', 'pending reminder'],
  ['Pedido de datasheet do conversor CC/CC', 'LRI', 'closed'],
].each do |title, group, state|
  ticket = Ticket.create!(
    title:        title,
    group:        Group.find_by(name: group),
    customer:     cliente,
    owner:        agente,
    state:        Ticket::State.find_by(name: state),
    priority:     priority,
    pending_time: state.start_with?('pending') ? 2.days.from_now : nil,
  )
  Ticket::Article.create!(ticket: ticket, type: web, sender: customer_sender, from: cliente.email, content_type: 'text/plain',
                          internal: false, created_by_id: cliente.id,
                          body: "Olá, #{title.downcase}. Podem ajudar? Veja https://www.lri.com.br")
  Ticket::Article.create!(ticket: ticket, type: note, sender: agent_sender, body: 'Nota interna: verificar estoque.',
                          content_type: 'text/plain', internal: true, created_by_id: agente.id)
end

cliente2 = User.find_by(login: 'cliente2@cliente.example.com')
ticket = Ticket.create!(title: 'Chamado do Cliente Dois (não deve aparecer ao Cliente Um)', group: Group.find_by(name: 'LRI'),
                        customer: cliente2, state: Ticket::State.find_by(name: 'new'), priority: priority)
Ticket::Article.create!(ticket: ticket, type: web, sender: customer_sender, from: cliente2.email, body: 'Teste de visibilidade.',
                        content_type: 'text/plain', internal: false, created_by_id: cliente2.id)

# O cliente escolhe só entre os grupos das marcas (o grupo padrão "Users" do Zammad fica de fora).
Setting.set('customer_ticket_create_group_ids', Group.where(name: ['LRI', 'IRD.Net', 'Mean Well Brasil']).pluck(:id).map(&:to_s))

kb = KnowledgeBase.first || KnowledgeBase.create!(
  iconset: 'FontAwesome', color_highlight: '#38ae6a', color_header: '#f9fafb', color_header_link: 'hsl(206,8%,50%)',
  homepage_layout: 'grid', category_layout: 'grid', category_sorting_mode: 'manual', active: true,
  kb_locales_attributes: [{ system_locale: Locale.find_by(locale: 'pt-br'), primary: true }]
)
kb_locale = kb.kb_locales.first
kb.translations.find_or_create_by!(kb_locale: kb_locale) do |translation|
  translation.title       = 'Central de Atendimento Grupo LRI'
  translation.footer_note = 'Grupo LRI'
end

# Ordem da ux-spec v2: LRI, IRD.Net, Mean Well Brasil.
[['LRI', 'f0e7'], ['IRD.Net', 'f1eb'], ['Mean Well Brasil', 'f0eb']].each_with_index do |(name, icon), position|
  category = KnowledgeBase::Category.create!(knowledge_base: kb, category_icon: icon, position: position,
                                             translations_attributes: [{ title: name, kb_locale: kb_locale }])
  answer = KnowledgeBase::Answer.create!(category: category, translations_attributes: [{
                                           title: "Como abrir um chamado #{name}", kb_locale: kb_locale,
                                           content_attributes: { body: "Abra pelo portal. Veja também <a href='https://www.lri.com.br'>o site</a>." }
                                         }])
  answer.update!(published_at: Time.zone.now, published_by_id: 1)
end

puts "chamados: #{Ticket.count}; respostas da KB: #{KnowledgeBase::Answer.count}"
