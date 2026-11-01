# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Resposta 403 da guarda de zona: JSON para a API, o GraphQL e chamadas XHR; página HTML simples para navegação.
# Texto em pt-BR, com o endereço interno da equipe. Nenhum detalhe do motivo vai ao cliente (fica só no log).
#
# Os textos são da instalação do Grupo LRI (pt-BR fixo), não do produto: ficam fora do catálogo de traduções do
# upstream de propósito.
class Lri::ZoneGuard::DenyResponse
  # rubocop:disable Zammad/DetectTranslatableString
  TITLE   = 'Acesso da equipe só pelo endereço interno'.freeze
  MESSAGE = 'Este endereço é o portal dos clientes. Atendimento e administração da Central de Atendimento ' \
            'Grupo LRI funcionam somente pelo endereço interno da equipe.'.freeze
  # rubocop:enable Zammad/DetectTranslatableString

  def initialize(request, internal_url)
    @request      = request
    @internal_url = internal_url
  end

  def to_rack
    json? ? json_response : html_response
  end

  private

  attr_reader :request, :internal_url

  def json?
    request.xhr? ||
      request.path.start_with?('/api/', '/graphql') ||
      request.headers['Accept'].to_s.include?('application/json') ||
      request.content_mime_type&.json?
  end

  def json_response
    body = { error: 'zone_restricted', error_human: "#{TITLE}. #{MESSAGE}", internal_url: internal_url.presence }.compact
    [403, { 'content-type' => 'application/json; charset=utf-8', 'cache-control' => 'no-store' }, [body.to_json]]
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
        <title>#{TITLE} — Central de Atendimento Grupo LRI</title>
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
          <h1>#{TITLE}</h1>
          <p>#{MESSAGE}</p>
          #{link}
        </main>
      </body>
      </html>
    HTML

    [403, { 'content-type' => 'text/html; charset=utf-8', 'cache-control' => 'no-store' }, [html]]
  end
end
