# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Guarda de zona: middleware Rack, logo depois do armazenamento de sessão e antes do OmniAuth e dos controllers
# (inclusive as rotas /oauth do Doorkeeper). Ver docs/lri/PLANO.md, seção 2.9.3, e Lri::ZonePolicy.
#
# Na zona pública:
#   - antes do app: recusa caminhos e cabeçalhos da equipe, e sessões que não podem ser usadas ali;
#   - depois do app: se a requisição criou uma sessão de equipe (login por senha, OmniAuth, SSO...), descarta a
#     resposta, encerra a sessão e recusa. Assim um login de agente nunca conclui pela zona pública.
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
    Rails.logger.warn "Lri::ZoneGuard: tratado como zona pública — #{zone.reason}" if zone.reason

    request = ActionDispatch::Request.new(env)

    if zone.public?
      reason = Lri::ZonePolicy.public_request_denial(env) || Lri::ZonePolicy.session_denial(session_hash(request), zone)
      return deny(request, config, reason) if reason
    end

    status, headers, body = @app.call(env)

    if zone.public? && (reason = Lri::ZonePolicy.session_denial(session_hash(request), zone))
      body.close if body.respond_to?(:close)
      return deny(request, config, "#{reason}, após a requisição")
    end

    stamp_zone(request, zone)
    [status, headers, body]
  end

  def self.zone_for_env(config, env)
    Lri::Zone.resolve(config, ->(name) { env["HTTP_#{name.upcase.tr('-', '_')}"] })
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
    request.reset_session
    Lri::ZoneGuard::DenyResponse.new(request, config.internal_url).to_rack
  end
end
