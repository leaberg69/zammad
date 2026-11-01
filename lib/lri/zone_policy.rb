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

    query_token_denial(env)
  end

  # Tokens na URL que autenticam sem sessão e sem current_user_set: feed da KB (?token=, FeedsController e
  #   FeedsControllerPolicy) e prévia da KB (?preview_token=, antes de ir para a sessão).
  QUERY_TOKENS = { 'token' => 'KnowledgeBaseFeed', 'preview_token' => 'KnowledgeBasePreview' }.freeze

  def query_token_denial(env)
    return if env['QUERY_STRING'].blank?

    params = Rack::Utils.parse_query(env['QUERY_STRING'])
    QUERY_TOKENS.each do |param, action|
      value = Array(params[param]).first
      next if value.blank?

      owner = Token.check(action: action, token: value)
      return "token #{action} da equipe na URL" if owner.present? && staff?(owner)
    end

    nil
  rescue ArgumentError => e # inclui Rack::Utils::InvalidParameterError; o Rails também recusa essa query
    Rails.logger.warn "Lri::ZonePolicy: query string ilegível ignorada na checagem de token (#{e.class})"
    nil
  end

  # session_data: hash da sessão (chaves em texto ou símbolo). Vale para HTTP, WebSocket legado e ActionCable.
  def session_denial(session_data, zone)
    return if zone.internal?
    return if session_data.blank?

    data = session_data.to_h.stringify_keys
    return 'sessão criada na zona interna' if data['lri_zone'] == Lri::Zone::INTERNAL
    return 'sessão com troca de usuário ("entrar como")' if data['switched_from_user_id'].present?
    return 'token de prévia da base de conhecimento da equipe' if staff_preview_token?(data['kb_preview_token'])
    return if data['user_id'].blank?

    user = User.lookup(id: data['user_id'])
    return if user.nil?
    return "usuário da equipe (id #{user.id})" if staff?(user)

    nil
  end

  # O token de prévia da KB fica na sessão e autentica sem user_id (KnowledgeBase::Public::BaseController e a
  #   política de anexos o leem direto da sessão).
  def staff_preview_token?(token)
    return false if token.blank?

    owner = Token.check(action: 'KnowledgeBasePreview', token: token)
    owner.present? && staff?(owner)
  end

  # Para o WebSocket legado, que guarda a sessão em memória pela vida da conexão e reconfere o usuário a cada
  #   evento: um socket aberto na zona pública não pode continuar autenticado se o usuário virou equipe.
  def realtime_user_allowed?(session_data, user)
    return true if session_data.to_h.stringify_keys['lri_zone'] != Lri::Zone::PUBLIC
    return true if user.nil?

    # Recarregado: conexões guardam o objeto do usuário do momento da conexão.
    !staff?(User.lookup(id: user.id) || user)
  end
end
