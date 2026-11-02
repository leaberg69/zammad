# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Provisionamento da Central de Atendimento Grupo LRI (docs/lri/PLANO.md, seções 2.2, 2.3 e 4): idioma, fuso,
# grupos por marca, organizações internas e perfis de agente. Idempotente: cria o que falta, corrige os atributos
# que o plano fixa e devolve um relatório linha a linha. Não apaga registros nem mexe em usuários.
class Lri::Provisioning
  SETTINGS = {
    'locale_default'   => 'pt-br',
    'timezone_default' => 'America/Sao_Paulo',
  }.freeze

  # Nomes de grupo são dados, não texto de interface.
  # rubocop:disable Zammad/DetectTranslatableString
  # Primeira camada: a marca; segunda: a fila. Os grupos Interno::* não aparecem para clientes.
  GROUPS = {
    'LRI'     => ['Suporte Técnico', 'Comercial', 'Financeiro'],
    'MW'      => ['Suporte'],
    'IRD'     => %w[Suporte Comercial],
    'Interno' => %w[TI Administrativo],
  }.freeze
  # rubocop:enable Zammad/DetectTranslatableString

  INTERNAL_BRANDS = %w[Interno].freeze

  ORGANIZATIONS = [
    { name: 'LRI Automação Industrial', domain: 'lri.com.br' },
    { name: 'IRD Produtos de Informática', domain: 'ird.net.br' },
  ].freeze

  # As permissões do perfil Agent nativo (db/seeds/permissions.rb), sem relatórios nem edição da base de conhecimento.
  AGENT_PERMISSIONS = %w[user_preferences ticket.agent chat.agent cti.agent knowledge_base.reader].freeze

  AGENT_ROLES = {
    'Agente LRI'              => 'LRI',
    'Agente Mean Well Brasil' => 'MW',
    'Agente IRD.Net'          => 'IRD',
    'Agente Interno'          => 'Interno',
  }.freeze

  ACTION_LABELS = { created: 'criado', updated: 'atualizado', unchanged: 'sem mudança', conflict: 'CONFLITO', warning: 'AVISO' }.freeze

  Result = Struct.new(:kind, :name, :action, :detail) do
    def to_s
      "#{ACTION_LABELS.fetch(action).ljust(11)} #{kind} #{name}#{" (#{detail})" if detail}"
    end
  end

  attr_reader :results

  # dry_run: aplica numa transação desfeita no fim, só para ler o relatório.
  def self.apply!(dry_run: false)
    new.tap { |provisioning| provisioning.apply!(dry_run:) }
  end

  def initialize
    @results = []
  end

  def apply!(dry_run: false)
    ActiveRecord::Base.transaction do
      UserInfo.ensure_current_user_id do
        apply_settings
        apply_groups
        apply_organizations
        apply_agent_roles
        apply_overviews
        apply_customer_groups
      end
      raise ActiveRecord::Rollback if dry_run || conflicts?
    end
    results
  end

  def changed?
    results.any? { |result| %i[created updated].include?(result.action) }
  end

  # Com conflito nada é gravado: o relatório diz qual registro impede o provisionamento.
  def conflicts?
    results.any? { |result| result.action == :conflict }
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

  # O banco diferencia maiúsculas, a validação de unicidade não: um nome igual em outra caixa vira conflito.
  def find_exact(model, kind, name)
    candidates = model.where('LOWER(name) = ?', name.downcase).to_a
    exact      = candidates.find { |candidate| candidate.name == name }
    return exact if exact
    return if candidates.empty?

    record(kind, name, :conflict, "já existe #{candidates.map { |candidate| candidate.name.inspect }.join(', ')}")
    :conflict
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
    group = find_exact(Group, :group, name)
    return if group == :conflict
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
      ensure_organization(attributes)
      warn_shared_domain(attributes)
    end
  end

  def ensure_organization(attributes)
    organization = find_exact(Organization, :organization, attributes[:name])
    return if organization == :conflict

    wanted = { shared: false, domain: attributes[:domain], domain_assignment: true, active: true }
    if organization.nil?
      Organization.create!(name: attributes[:name], **wanted)
      return record(:organization, attributes[:name], :created)
    end

    diff = wanted.reject { |key, value| organization.public_send(key) == value }
    return record(:organization, attributes[:name], :unchanged) if diff.empty?

    organization.update!(diff)
    record(:organization, attributes[:name], :updated, diff.keys.join(', '))
  end

  def warn_shared_domain(attributes)
    others = Organization.where(domain: attributes[:domain], domain_assignment: true).where.not(name: attributes[:name]).pluck(:name)
    return if others.empty?

    record(:organization, attributes[:name], :warning, "domínio #{attributes[:domain]} também atribuído a #{others.join(', ')}")
  end

  def agent_permission_ids
    @agent_permission_ids ||= AGENT_PERMISSIONS.map { |name| Permission.find_by!(name: name).id }.sort
  end

  def apply_agent_roles
    AGENT_ROLES.each do |name, brand|
      role = find_exact(Role, :role, name)
      next if role == :conflict

      access = self.class.group_names(brand).index_with { 'full' }
      next create_agent_role(name, access) if role.nil?

      update_agent_role(role, access)
    end
  end

  def create_agent_role(name, access)
    role = Role.create!(name: name, active: true, default_at_signup: false, permission_ids: agent_permission_ids)
    role.group_names_access_map = access
    record(:role, name, :created)
  end

  def update_agent_role(role, access)
    changes = []
    changes << describe_change('permissões', role.permissions.pluck(:name), AGENT_PERMISSIONS) if role.permission_ids.sort != agent_permission_ids
    changes << 'reativado' if !role.active?
    changes << 'default_at_signup desligado' if role.default_at_signup

    role.update!(active: true, default_at_signup: false, permission_ids: agent_permission_ids) if changes.any?

    current = normalized(role.reload.saved_group_names_access_map)
    if current != normalized(access)
      changes << describe_change('grupos', current.keys, access.keys)
      role.group_names_access_map = access
    end

    return record(:role, role.name, :unchanged) if changes.empty?

    record(:role, role.name, :updated, changes.join('; '))
  end

  # As visões padrão de chamados pertencem ao perfil Agent; quem só tem o perfil da marca também precisa delas.
  def apply_overviews
    brand_roles = Role.where(name: AGENT_ROLES.keys).to_a
    Overview.joins(:roles).where(roles: { name: 'Agent' }).distinct.find_each do |overview|
      missing = brand_roles - overview.roles.to_a
      next record(:overview, overview.name, :unchanged) if missing.empty?

      overview.role_ids = overview.role_ids + missing.map(&:id)
      overview.save!
      record(:overview, overview.name, :updated, "perfis #{missing.map(&:name).join(', ')}")
    end
  end

  def apply_customer_groups
    wanted_names  = self.class.customer_group_names
    wanted        = Group.where(name: wanted_names).reorder(:id).pluck(:id).map(&:to_s)
    current       = Array(Setting.get('customer_ticket_create_group_ids')).map(&:to_s).sort_by(&:to_i)
    return record(:setting, 'customer_ticket_create_group_ids', :unchanged) if current == wanted

    current_names = Group.where(id: current).pluck(:name)
    Setting.set('customer_ticket_create_group_ids', wanted)
    record(:setting, 'customer_ticket_create_group_ids', :updated, describe_change('grupos', current_names, wanted_names))
  end

  def normalized(access_map)
    access_map.transform_values { |access| Array(access).map(&:to_s).sort }
  end

  def describe_change(label, before, after)
    added   = after - before
    removed = before - after
    return "#{label}: nível de acesso" if added.empty? && removed.empty?

    "#{label}: #{"+#{added.join(', ')}" if added.any?}#{' ' if added.any? && removed.any?}#{"-#{removed.join(', ')}" if removed.any?}"
  end
end
