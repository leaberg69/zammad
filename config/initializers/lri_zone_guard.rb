# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Guarda de zona da Central de Atendimento Grupo LRI (docs/lri/PLANO.md, seção 2.9.3).
# Fica sempre na pilha; só age com LRI_ZONE_GUARD=enforce (ver Lri::Zone::Config).
#
# O middleware registrado aqui é só uma casca: Lri::ZoneGuard (lib/, recarregável) é resolvido a cada requisição,
# porque constantes recarregáveis não podem ser carregadas durante a inicialização.
class LriZoneGuardMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    Lri::ZoneGuard.new(@app).call(env)
  end
end

Rails.application.config.middleware.insert_after ActionDispatch::Session::ActiveRecordStore, LriZoneGuardMiddleware

# Monitor externo (docs/lri/GO-LIVE.md, seção 12): o Nginx entrega o token de monitoramento no cabeçalho
# X-LRI-Monitor-Token, fora de qualquer URL (nem a dele nem a do upstream vão para um log com a credencial). Aqui o
# cabeçalho vira o parâmetro token do health check, que o Zammad lê de params[:token]: só no caminho exato e sem
# query. Em qualquer outro caso o cabeçalho é descartado. Fica depois da guarda, que recusa o caminho na zona pública.
class LriMonitorTokenMiddleware
  HEADER = 'HTTP_X_LRI_MONITOR_TOKEN'.freeze
  PATH   = '/api/v1/monitoring/health_check'.freeze
  # Parâmetros de query já lidos por quem veio antes na pilha; descartados para a nova query valer.
  QUERY_CACHES = %w[action_dispatch.request.query_parameters rack.request.query_hash rack.request.query_string].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    token = env.delete(HEADER)
    if token.present? && env['PATH_INFO'] == PATH && env['QUERY_STRING'].blank?
      env['QUERY_STRING'] = Rack::Utils.build_query('token' => token)
      QUERY_CACHES.each { |key| env.delete(key) }
    end
    @app.call(env)
  end
end

Rails.application.config.middleware.insert_after LriZoneGuardMiddleware, LriMonitorTokenMiddleware

# Organizações novas sem compartilhamento e filas por público no servidor, reaplicados a cada recarga de código.
Rails.application.config.to_prepare do
  Organization.include(Lri::PrivateOrganizations) if !(Organization < Lri::PrivateOrganizations)
  Ticket.include(Lri::QueueAudience) if !(Ticket < Lri::QueueAudience)
  CoreWorkflow::Attributes::Group.prepend(Lri::QueueAudience::GroupOptions) if CoreWorkflow::Attributes::Group.ancestors.exclude?(Lri::QueueAudience::GroupOptions)
end

# Guarda ligada com configuração incompleta não sobe: melhor parar na partida do que proteger pela metade.
Rails.application.config.after_initialize do
  config = Lri::Zone::Config.current
  config.validate!
  Rails.logger.info config.describe
  if config.enforced?
    begin
      Rails.logger.info config.describe_emergency
    rescue ActiveRecord::ActiveRecordError => e # banco ainda não criado (ex.: primeira partida, db:create)
      Rails.logger.warn "Lri::Zone::Config: conta de emergência não conferida na partida (#{e.class})"
    end
  end
end
