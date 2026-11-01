# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Dados de teste para as capturas do UX-B (contrib/lri/qa/capture.py). Só para instância local; nunca produção.
# Uso: bundle exec rails runner contrib/lri/qa/seed.rb (depois do wizard.json aplicado por AutoWizard.setup).

UserInfo.current_user_id = 1
c = User.find_by(login: 'cliente1@cliente.example.com')
ag = User.find_by(login: 'agente@lri.example')
[['Fonte HRP-150-24 não liga', 'LRI', 'open'], ['Switch IRD com porta SFP sem link', 'IRD.Net', 'pending reminder'], ['Pedido de datasheet do conversor CC/CC', 'LRI', 'closed']].each do |t, g, st|
  tk = Ticket.create!(title: t, group: Group.find_by(name: g), customer: c, owner: ag, state: Ticket::State.find_by(name: st), priority: Ticket::Priority.find_by(name: '2 normal'), pending_time: (st.start_with?('pending') ? 2.days.from_now : nil))
  Ticket::Article.create!(ticket: tk, type: Ticket::Article::Type.find_by(name: 'web'), sender: Ticket::Article::Sender.find_by(name: 'Customer'), from: c.email, body: "Olá, #{t.downcase}. Podem ajudar? Veja https://www.lri.com.br", content_type: 'text/plain', internal: false, created_by_id: c.id)
  Ticket::Article.create!(ticket: tk, type: Ticket::Article::Type.find_by(name: 'note'), sender: Ticket::Article::Sender.find_by(name: 'Agent'), body: 'Nota interna: verificar estoque.', content_type: 'text/plain', internal: true, created_by_id: ag.id)
end
c2 = User.find_by(login: 'cliente2@cliente.example.com')
tk = Ticket.create!(title: 'Chamado do Cliente Dois (não deve aparecer ao Cliente Um)', group: Group.find_by(name: 'LRI'), customer: c2, state: Ticket::State.find_by(name: 'new'), priority: Ticket::Priority.find_by(name: '2 normal'))
Ticket::Article.create!(ticket: tk, type: Ticket::Article::Type.find_by(name: 'web'), sender: Ticket::Article::Sender.find_by(name: 'Customer'), from: c2.email, body: 'Teste de visibilidade.', content_type: 'text/plain', internal: false, created_by_id: c2.id)
kb = KnowledgeBase.first || KnowledgeBase.create!(iconset: 'FontAwesome', color_highlight: '#38ae6a', color_header: '#f9fafb', color_header_link: 'hsl(206,8%,50%)', homepage_layout: 'grid', category_layout: 'grid', active: true, kb_locales_attributes: [{ system_locale: Locale.find_by(locale: 'pt-br'), primary: true }])
kl = kb.kb_locales.first
kb.translations.find_or_create_by!(kb_locale: kl) { |tr| tr.title = 'Central de Atendimento Grupo LRI'; tr.footer_note = 'Grupo LRI' }
['LRI', 'IRD.Net', 'Mean Well Brasil'].each_with_index do |n, i|
  cat = KnowledgeBase::Category.create!(knowledge_base: kb, category_icon: %w[f0e7 f1eb f0eb][i], translations_attributes: [{ title: n, kb_locale: kl }])
  a = KnowledgeBase::Answer.create!(category: cat, translations_attributes: [{ title: "Como abrir um chamado #{n}", kb_locale: kl, content_attributes: { body: "Abra pelo portal. Veja também <a href='https://www.lri.com.br'>o site</a>." } }])
  a.update!(published_at: Time.zone.now, published_by_id: 1)
end
puts Ticket.count, KnowledgeBase::Answer.count
