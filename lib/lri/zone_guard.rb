# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Guarda de zona: middleware Rack, logo depois do armazenamento de sessão e antes do OmniAuth e dos controllers
# (inclusive as rotas /oauth do Doorkeeper). Ver docs/lri/PLANO.md, seção 2.9.3, e Lri::ZonePolicy.
#
# Na zona pública:
#   - antes do app: recusa caminhos e cabeçalhos da equipe, e sessões que não podem ser usadas ali;
#   - durante o app: ApplicationController::HasUser#current_user_set (por onde passam todos os logins: senha REST
#     e GraphQL, token, autenticação básica, SSO, OmniAuth) chama .authenticating!, que impede a equipe de virar
#     usuário corrente e marca a requisição, então nada roda em nome da equipe nessa requisição;
#   - depois do app: se a requisição foi marcada, ou terminou com uma sessão que não pode ficar na zona pública,
#     descarta a resposta inteira, encerra a sessão e recusa.
# Em qualquer zona, a sessão recebe a zona em que nasceu (session['lri_zone']).
#
# Toda recusa é registrada no log com o motivo (sem segredos) e devolvida com código 403 e o endereço interno.
class Lri::ZoneGuard
  def initialize(app, config_provider: -> { Lri::Zone::Config.current })
    @app             = app
    @config_provider = config_provider
  end

  def call(env)
    config = @config_provider.call
    return @app.call(env) if !config.enforced?

    zone = self.class.zone_for_env(config, env)
    env['lri.zone'] = zone
    Lri::Current.zone = zone

    request = ActionDispatch::Request.new(env)

    # O listener interno reivindicou a zona, mas a prova não fechou (JWT inválido, chaves do Access indisponíveis,
    # segredo errado). Responde 503 sem tocar na sessão: uma falha de disponibilidade do Access não pode desconectar
    # a equipe inteira. Quem não tem o segredo nem passou pelo Access não ganha nada com isso.
    return unavailable(request, config, zone.reason) if zone.reason

    if zone.public?
      reason = Lri::ZonePolicy.public_request_denial(env) || Lri::ZonePolicy.session_denial(session_hash(request), zone)
      return deny(request, config, reason) if reason
    end

    status, headers, body = @app.call(env)

    if zone.public? && (reason = env[DENIED_KEY] || Lri::ZonePolicy.session_denial(session_hash(request), zone))
      body.close if body.respond_to?(:close)
      return deny(request, config, "#{reason}, após a requisição")
    end

    stamp_zone(request, zone)
    [status, headers, body]
  end

  DENIED_KEY = 'lri.zone.denied'.freeze

  # Erro levantado quando a equipe tenta se autenticar na zona pública. É um Forbidden do Zammad, então os
  # controllers e o GraphQL tratam como recusa; o middleware ainda troca a resposta pela recusa da guarda.
  class StaffInPublicZone < Exceptions::Forbidden; end

  def self.zone_for_env(config, env)
    Lri::Zone.resolve(config, ->(name) { env["HTTP_#{name.upcase.tr('-', '_')}"] })
  end

  # Chamado em ApplicationController::HasUser#current_user_set, antes de o usuário virar o corrente. Sem zona no env
  # (guarda desligada ou fora de uma requisição HTTP) não faz nada.
  def self.authenticating!(env, user)
    zone = env['lri.zone']
    return if zone.nil? || zone.internal?
    return if !Lri::ZonePolicy.staff?(user)

    reason = "login de usuário da equipe (id #{user.id}) na zona pública"
    env[DENIED_KEY] ||= reason
    raise StaffInPublicZone, reason
  end

  # Provedores de login de terceiros, todos recusados na zona pública: a interface de lá não mostra os botões.
  PUBLIC_HIDDEN_SETTINGS = %w[
    auth_facebook auth_github auth_gitlab auth_google_oauth2 auth_linkedin auth_microsoft_office365
    auth_openid_connect auth_saml auth_sso auth_twitter auth_weibo
  ].freeze

  # Valor de uma configuração entregue à interface. Com a guarda ligada, só a zona interna vê os provedores.
  def self.frontend_value(zone_name, setting_name, value, config: Lri::Zone::Config.current)
    return value if !config.enforced? || zone_name == 'internal'
    return value if PUBLIC_HIDDEN_SETTINGS.exclude?(setting_name)

    false
  end

  # Zona de uma requisição GraphQL, gravada no contexto pelo GraphqlController e pelo GraphqlChannel.
  def self.graphql_zone_name(context)
    context[:lri_zone]
  end

  # Zona de uma conexão de tempo real, para o WebSocket legado gravar na sessão da conexão; nil com a guarda desligada.
  def self.realtime_zone_name(header_lookup, config: Lri::Zone::Config.current)
    return if !config.enforced?

    Lri::Zone.resolve(config, header_lookup).name
  end

  # ActionCable: a conexão guarda a zona em que nasceu (ApplicationCable::Connection#lri_zone). GraphqlChannel e a
  # entrega de assinaturas chamam isto antes de servir um usuário; false = a conexão pública virou de equipe.
  def self.cable_allowed?(connection)
    user = connection.current_user
    return true if user.nil?

    lri_zone = connection.respond_to?(:lri_zone) ? connection.lri_zone : nil
    allowed  = Lri::ZonePolicy.realtime_user_allowed?({ 'lri_zone' => lri_zone }, user)
    Rails.logger.warn "Lri::ZoneGuard: conexão ActionCable pública do usuário #{user.id}, que agora é da equipe, encerrada" if !allowed
    allowed
  end

  # Encerra a conexão ActionCable; o cliente reconecta e, na zona pública, volta sem usuário.
  def self.close_cable(connection)
    connection.close(reason: ActionCable::INTERNAL[:disconnect_reasons][:unauthorized], reconnect: true)
    nil
  end

  # Para os transportes de tempo real (WebSocket legado e ActionCable), que autenticam fora do fluxo Rack dos
  # controllers. Devolve o motivo da recusa ou nil.
  def self.realtime_denial(session_data, header_lookup, config: Lri::Zone::Config.current)
    return if !config.enforced?

    zone   = Lri::Zone.resolve(config, header_lookup)
    reason = Lri::ZonePolicy.session_denial(session_data, zone)
    Rails.logger.warn "Lri::ZoneGuard: tempo real recusado na zona pública — #{reason}#{" (#{zone.reason})" if zone.reason}" if reason
    reason
  end

  private

  def session_hash(request)
    session = request.session
    return {} if !session.respond_to?(:to_hash)

    session.to_hash
  end

  def stamp_zone(request, zone)
    session = request.session
    return if session[:user_id].blank? || session[:lri_zone].present?

    session[:lri_zone] = zone.name
  end

  def deny(request, config, reason)
    Rails.logger.warn "Lri::ZoneGuard: recusado #{request.request_method} #{request.path} — #{reason}"
    request.reset_session if request.session.respond_to?(:id) && request.session.id.present?
    Lri::ZoneGuard::DenyResponse.new(request, config.internal_url).to_rack
  end

  def unavailable(request, config, reason)
    Rails.logger.error "Lri::ZoneGuard: zona interna não confirmada em #{request.request_method} #{request.path} — #{reason}"
    Lri::ZoneGuard::DenyResponse.new(request, config.internal_url, kind: :unavailable).to_rack
  end
end
