# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Zona de uma requisição na Central de Atendimento Grupo LRI (docs/lri/PLANO.md, seção 2.9).
#
# Uma requisição só é da zona interna quando traz, ao mesmo tempo:
#   1. X-LRI-Zone: internal (texto exato, escrito pelo listener interno do Nginx da central);
#   2. X-LRI-Zone-Key igual ao segredo de zona da instância (só o listener interno conhece);
#   3. Cf-Access-Jwt-Assertion válido (assinatura da equipe do Cloudflare Access, audience do aplicativo e validade).
# Qualquer outra combinação é zona pública (falha fechada). O motivo de cada rebaixamento fica em #reason.
class Lri::Zone
  INTERNAL = 'internal'.freeze
  PUBLIC   = 'public'.freeze

  ZONE_HEADER = 'X-LRI-Zone'.freeze
  KEY_HEADER  = 'X-LRI-Zone-Key'.freeze
  JWT_HEADER  = 'Cf-Access-Jwt-Assertion'.freeze

  attr_reader :name, :reason

  def initialize(name, reason = nil)
    @name   = name
    @reason = reason
  end

  def internal?
    name == INTERNAL
  end

  def public?
    !internal?
  end

  # header_lookup: lambda que recebe o nome do cabeçalho e devolve o valor (ou nil).
  def self.resolve(config, header_lookup)
    claimed = header_lookup.call(ZONE_HEADER)
    return new(PUBLIC) if claimed != INTERNAL

    key = header_lookup.call(KEY_HEADER).to_s
    if key.blank? || !ActiveSupport::SecurityUtils.secure_compare(key, config.zone_key)
      return new(PUBLIC, 'X-LRI-Zone internal sem o segredo de zona correto') # rubocop:disable Zammad/DetectTranslatableString
    end

    jwt_reason = config.access_verifier.failure_reason(header_lookup.call(JWT_HEADER))
    return new(PUBLIC, "X-LRI-Zone internal sem JWT válido do Cloudflare Access: #{jwt_reason}") if jwt_reason

    new(INTERNAL)
  end
end
