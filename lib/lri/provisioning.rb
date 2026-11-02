# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Provisionamento da Central de Atendimento Grupo LRI (docs/lri/PLANO.md, seções 2.2, 2.3 e 4): idioma, fuso,
# grupos por marca, organizações internas e perfis de agente. Idempotente: cria o que falta, corrige os atributos
# que o plano fixa e devolve um relatório linha a linha. Não apaga nada nem mexe em usuários.
class Lri::Provisioning
  SETTINGS = {
    'locale_default'   => 'pt-br',
    'timezone_default' => 'America/Sao_Paulo',
  }.freeze

  # Primeira camada: a marca; segunda: a fila. Os grupos Interno::* não aparecem para clientes.
  GROUPS = {
    'LRI'     => ['Suporte Técnico', 'Comercial', 'Financeiro'],
    'MW'      => ['Suporte'],
    'IRD'     => %w[Suporte Comercial],
    'Interno' => %w[TI Administrativo],
  }.freeze

  INTERNAL_BRANDS = %w[Interno].freeze

  ORGANIZATIONS = [
    { name: 'LRI Automação Industrial', domain: 'lri.com.br' },
    { name: 'IRD Produtos de Informática', domain: 'ird.net.br' },
  ].freeze

  # Perfil de agente por marca: as permissões do perfil Agent nativo, com acesso total só aos grupos da marca.
  AGENT_ROLES = {
    'Agente LRI'              => 'LRI',
    'Agente Mean Well Brasil' => 'MW',
    'Agente IRD.Net'          => 'IRD',
    'Agente Interno'          => 'Interno',
  }.freeze

  Result = Struct.new(:kind, :name, :action, :detail) do
    def to_s
      "#{action.to_s.ljust(10)} #{kind} #{name}#{" (#{detail})" if detail}"
    end
  end

  attr_reader :results

  def self.apply!
    new.tap(&:apply!)
  end

  def initialize
    @results = []
  end

  def apply!
    ActiveRecord::Base.transaction do
      UserInfo.ensure_current_user_id do
        apply_settings
        apply_groups
        apply_organizations
        apply_agent_roles
        apply_customer_groups
      end
    end
    results
  end

  def changed?
    results.any? { |result| result.action != :unchanged }
  end

  def self.group_names(brand)
    [brand] + GROUPS.fetch(brand).map { |queue| "#{brand}::#{queue}" }
  end

  def self.customer_group_names
    (GROUPS.keys - INTERNAL_BRANDS).flat_map { |brand| group_names(brand).drop(1) }
  end

  private

  def record(kind, name, action, detail = nil)
    @results << Result.new(kind, name, action, detail)
  end

  def apply_settings
    SETTINGS.each do |name, value|
      current = Setting.get(name)
      next record(:setting, name, :unchanged) if current == value

      Setting.set(name, value)
      record(:setting, name, :updated, "#{current.inspect} -> #{value.inspect}")
    end
  end

  def apply_groups
    GROUPS.each_key do |brand|
      self.class.group_names(brand).each { |name| ensure_group(name) }
    end
  end

  def ensure_group(name)
    group = Group.find_by(name: name)
    return record(:group, name, :unchanged) if group&.active?

    if group
      group.update!(active: true)
      return record(:group, name, :updated, 'reativado')
    end

    Group.create!(name: name, active: true)
    record(:group, name, :created)
  end

  def apply_organizations
    ORGANIZATIONS.each do |attributes|
      organization = Organization.find_by(name: attributes[:name])
      wanted = { shared: false, domain: attributes[:domain], domain_assignment: true, active: true }

      if organization.nil?
        Organization.create!(name: attributes[:name], **wanted)
        next record(:organization, attributes[:name], :created)
      end

      diff = wanted.reject { |key, value| organization.public_send(key) == value }
      next record(:organization, attributes[:name], :unchanged) if diff.empty?

      organization.update!(diff)
      record(:organization, attributes[:name], :updated, diff.keys.join(', '))
    end
  end

  def apply_agent_roles
    agent_permission_ids = Role.find_by!(name: 'Agent').permission_ids

    AGENT_ROLES.each do |name, brand|
      access = self.class.group_names(brand).index_with { 'full' }
      role   = Role.find_by(name: name)

      if role.nil?
        role = Role.create!(name: name, active: true, permission_ids: agent_permission_ids, default_at_signup: false)
        role.group_names_access_map = access
        next record(:role, name, :created)
      end

      next record(:role, name, :unchanged) if normalized(role.group_names_access_map) == normalized(access)

      role.group_names_access_map = access
      record(:role, name, :updated, 'acesso aos grupos')
    end
  end

  def normalized(access_map)
    access_map.transform_values { |access| Array(access).map(&:to_s).sort }
  end

  def apply_customer_groups
    wanted  = Group.where(name: self.class.customer_group_names).order(:id).pluck(:id).map(&:to_s)
    current = Array(Setting.get('customer_ticket_create_group_ids')).map(&:to_s).sort_by(&:to_i)
    return record(:setting, 'customer_ticket_create_group_ids', :unchanged) if current == wanted

    Setting.set('customer_ticket_create_group_ids', wanted)
    record(:setting, 'customer_ticket_create_group_ids', :updated, "#{wanted.size} grupos de clientes")
  end
end
