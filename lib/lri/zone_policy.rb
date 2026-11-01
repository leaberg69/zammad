# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Regras da guarda de zona (docs/lri/PLANO.md, seção 2.9.3). Cada método devolve nil quando a requisição pode seguir,
# ou o motivo da recusa.
module Lri::ZonePolicy
  # Permissões de cliente. Qualquer outra (agente, administração, relatórios, e as que o upstream criar no futuro)
  # torna o usuário "equipe" — a lista é de permitidos, então permissão nova cai do lado fechado.
  CUSTOMER_PERMISSION_PREFIXES = %w[ticket.customer user_preferences knowledge_base.reader].freeze

  # Caminhos que nunca servem à zona pública. Comparação sem diferenciar maiúsculas (como o OmniAuth) e sobre o
  # caminho com barras repetidas juntadas (como o roteador do Rails).
  PUBLIC_FORBIDDEN_PATHS = %r{\A/(auth|oauth|api/v1/external_credentials|api/v1/monitoring)(/|\z)}i

  # Credenciais por cabeçalho: clientes usam o portal com sessão, então na zona pública nada disso é aceito, de
  # ninguém (token de API, autenticação básica, bearer OAuth2, SSO por cabeçalho). As variantes de Authorization são
  # as que ActionDispatch::Request#authorization também lê. "From"/"X-On-Behalf-Of" não entram: só personificam com
  # um usuário autenticado que tenha a permissão, e robôs de busca mandam "From" na KB pública.
  PUBLIC_FORBIDDEN_HEADERS = %w[
    HTTP_AUTHORIZATION X-HTTP_AUTHORIZATION X_HTTP_AUTHORIZATION REDIRECT_X_HTTP_AUTHORIZATION
    HTTP_REMOTE_USER HTTP_X_FORWARDED_USER REMOTE_USER
  ].freeze

  module_function

  def staff?(user)
    user.permissions_with_child_names.any? do |name|
      CUSTOMER_PERMISSION_PREFIXES.none? { |prefix| name == prefix || name.start_with?("#{prefix}.") }
    end
  end

  def public_request_denial(env)
    path = env['PATH_INFO'].to_s.squeeze('/')
    return "caminho reservado à equipe (#{path[0, 80]})" if PUBLIC_FORBIDDEN_PATHS.match?(path)

    header = PUBLIC_FORBIDDEN_HEADERS.find { |name| env[name].present? }
    return "cabeçalho de credencial (#{header})" if header

    nil
  end

  # session_data: hash da sessão (chaves em texto ou símbolo). Vale para HTTP, WebSocket legado e ActionCable.
  def session_denial(session_data, zone)
    return if zone.internal?
    return if session_data.blank?

    data = session_data.to_h.stringify_keys
    return 'sessão criada na zona interna' if data['lri_zone'] == Lri::Zone::INTERNAL
    return 'sessão com troca de usuário ("entrar como")' if data['switched_from_user_id'].present?
    return if data['user_id'].blank?

    user = User.lookup(id: data['user_id'])
    return if user.nil?
    return "usuário da equipe (id #{user.id})" if staff?(user)

    nil
  end
end
