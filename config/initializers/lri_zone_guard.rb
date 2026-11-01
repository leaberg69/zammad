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

# Organizações novas sem compartilhamento (Lri::PrivateOrganizations), reaplicado a cada recarga de código.
Rails.application.config.to_prepare do
  Organization.include(Lri::PrivateOrganizations) if !Organization.include?(Lri::PrivateOrganizations)
end

# Guarda ligada com configuração incompleta não sobe: melhor parar na partida do que proteger pela metade.
Rails.application.config.after_initialize do
  config = Lri::Zone::Config.current
  config.validate!
  Rails.logger.info config.describe
end
