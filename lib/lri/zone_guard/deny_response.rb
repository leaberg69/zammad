# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Respostas da guarda de zona, em JSON para a API, o GraphQL e chamadas XHR, e em HTML simples para navegação:
#   :restricted  403 — rota ou sessão da equipe no portal público;
#   :unavailable 503 — o endereço interno não conseguiu confirmar o acesso (Cloudflare Access), tentar de novo.
# Texto em pt-BR, com o endereço interno da equipe. O motivo técnico fica só no log.
#
# Os textos são da instalação do Grupo LRI (pt-BR fixo), não do produto: ficam fora do catálogo de traduções do
# upstream de propósito.
class Lri::ZoneGuard::DenyResponse
  # rubocop:disable-next Zammad/DetectTranslatableString
  TEXTS = {
    restricted:  {
      status:  403,
      error:   'zone_restricted',
      title:   'Acesso da equipe só pelo endereço interno',
      message: 'Este endereço é o portal dos clientes. Atendimento e administração da Central de Atendimento ' \
               'Grupo LRI funcionam somente pelo endereço interno da equipe.',
    },
    unavailable: {
      status:  503,
      error:   'zone_unconfirmed',
      title:   'Não foi possível confirmar o acesso da equipe',
      message: 'O endereço interno da Central de Atendimento Grupo LRI não conseguiu confirmar o seu login no ' \
               'Cloudflare Access. Recarregue a página em alguns instantes; se continuar, avise a TI.',
    },
  }.freeze

  def initialize(request, internal_url, kind: :restricted)
    @request      = request
    @internal_url = internal_url
    @text         = TEXTS.fetch(kind)
  end

  def to_rack
    json? ? json_response : html_response
  end

  private

  attr_reader :request, :internal_url, :text

  def headers(type)
    { 'content-type' => "#{type}; charset=utf-8", 'cache-control' => 'no-store' }
  end

  def json?
    request.xhr? ||
      request.path.start_with?('/api/', '/graphql') ||
      request.headers['Accept'].to_s.include?('application/json') ||
      json_content_type?
  end

  # Content-Type malformado não pode transformar a recusa num erro 4xx/5xx genérico.
  def json_content_type?
    request.content_mime_type&.json?
  rescue ActionDispatch::Http::MimeNegotiation::InvalidType
    false
  end

  def json_response
    body = { error: text[:error], error_human: "#{text[:title]}. #{text[:message]}", internal_url: internal_url.presence }.compact
    [text[:status], headers('application/json'), [body.to_json]]
  end

  def html_response
    link = if internal_url.present?
             url = ERB::Util.html_escape(internal_url)
             %(<p><a href="#{url}">#{url}</a></p>)
           else
             ''
           end

    html = <<~HTML
      <!DOCTYPE html>
      <html lang="pt-BR">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>#{text[:title]} — Central de Atendimento Grupo LRI</title>
        <style>
          body { margin: 0; font-family: system-ui, sans-serif; background: #f9fafb; color: #202021; }
          main { max-width: 36rem; margin: 15vh auto 0; padding: 0 16px; }
          h1 { font-size: 1.4rem; }
          a { color: #3d7a12; }
          a:focus-visible { outline: 3px solid #3d7a12; outline-offset: 2px; }
        </style>
      </head>
      <body>
        <main>
          <h1>#{text[:title]}</h1>
          <p>#{text[:message]}</p>
          #{link}
        </main>
      </body>
      </html>
    HTML

    [text[:status], headers('text/html'), [html]]
  end
end
