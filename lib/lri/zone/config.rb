# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Configuração da guarda de zona, lida das variáveis de ambiente da instância.
#
#   LRI_ZONE_GUARD=enforce         liga a guarda (qualquer outro valor: desligada, comportamento do upstream)
#   LRI_ZONE_KEY                   segredo de zona, mínimo 32 caracteres, só no listener interno e no Zammad
#   LRI_ACCESS_TEAM_DOMAIN         domínio da equipe do Cloudflare Access, ex.: lriauto.cloudflareaccess.com
#   LRI_ACCESS_AUD                 audience (AUD tag) do aplicativo do Access; várias separadas por vírgula
#   LRI_INTERNAL_URL               endereço interno da equipe, ex.: https://atendimento.lri.com.br
#   LRI_EMERGENCY_LOGIN            (opcional) login da conta de emergência, a única da equipe com senha
#   LRI_ORGANIZATIONS_PRIVATE=true (opcional) organizações novas nascem com "Organização compartilhada" desligada
#
# Com a guarda ligada, configuração incompleta impede a subida (Lri::Zone::Config#validate!), em vez de deixar a
# guarda funcionando pela metade.
class Lri::Zone::Config
  MIN_KEY_LENGTH = 32

  attr_reader :env

  def self.current
    new(ENV)
  end

  def initialize(env)
    @env = env
  end

  def enforced?
    env['LRI_ZONE_GUARD'] == 'enforce'
  end

  def zone_key
    env['LRI_ZONE_KEY'].to_s
  end

  def team_domain
    env['LRI_ACCESS_TEAM_DOMAIN'].to_s.strip
  end

  def audiences
    env['LRI_ACCESS_AUD'].to_s.split(',').map(&:strip).compact_blank
  end

  def internal_url
    env['LRI_INTERNAL_URL'].to_s.strip
  end

  # Só pelo login, que é único (o e-mail pode se repetir com user_email_multiple_use).
  def emergency_login
    env['LRI_EMERGENCY_LOGIN'].to_s.strip
  end

  def emergency_account?(user)
    return false if emergency_login.blank? || user.nil?

    user.login.to_s.casecmp?(emergency_login)
  end

  def describe_emergency
    return 'conta de emergência: nenhuma (LRI_EMERGENCY_LOGIN vazio)' if emergency_login.blank?

    user = User.find_by(login: emergency_login.downcase)
    return "conta de emergência: login #{emergency_login.inspect} NÃO encontrado" if user.nil?
    return "conta de emergência: #{user.login} SEM 2FA do Zammad cadastrado (não vai entrar)" if !Auth::User.new(user.login).requires_two_factor?

    "conta de emergência: #{user.login}, com 2FA"
  end

  def organizations_private?
    env['LRI_ORGANIZATIONS_PRIVATE'] == 'true'
  end

  def access_verifier
    Lri::Zone::AccessVerifier.for(team_domain:, audiences:)
  end

  ACCEPTED_MODES = ['', 'off', 'enforce'].freeze

  def mode
    env['LRI_ZONE_GUARD'].to_s
  end

  def problems
    # Valor desconhecido ("enforced", "Enforce", "true"...) não pode desligar a guarda em silêncio.
    return ["LRI_ZONE_GUARD=#{mode.inspect} não é reconhecido (use 'enforce' ou 'off')"] if ACCEPTED_MODES.exclude?(mode)
    return [] if !enforced?

    list = []
    list << "LRI_ZONE_KEY precisa ter ao menos #{MIN_KEY_LENGTH} caracteres" if zone_key.length < MIN_KEY_LENGTH
    list << 'LRI_ACCESS_TEAM_DOMAIN ausente ou inválido (esperado <equipe>.cloudflareaccess.com)' if !team_domain.match?(%r{\A[a-z0-9-]+\.cloudflareaccess\.com\z})
    list << 'LRI_ACCESS_AUD ausente' if audiences.empty?
    list << 'LRI_INTERNAL_URL ausente ou sem https://' if !internal_url.start_with?('https://')
    list
  end

  def validate!
    return if problems.empty?

    raise ArgumentError, "Guarda de zona LRI com configuração inválida: #{problems.join('; ')}"
  end

  def describe
    return "guarda de zona LRI LIGADA (enforce), endereço interno #{internal_url}" if enforced?

    'guarda de zona LRI desligada (LRI_ZONE_GUARD não é "enforce"): equipe e clientes sem separação por zona'
  end
end
