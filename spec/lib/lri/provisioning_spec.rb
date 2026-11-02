# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::Provisioning do
  subject(:provisioning) { described_class.apply! }

  def result_for(run, name)
    run.results.find { |entry| entry.name == name }
  end

  it 'sets the language and the time zone', :aggregate_failures do
    provisioning

    expect(Setting.get('locale_default')).to eq('pt-br')
    expect(Setting.get('timezone_default')).to eq('America/Sao_Paulo')
  end

  it 'creates the brand groups with their queues as children', :aggregate_failures do
    provisioning

    expect(Group.find_by(name: 'LRI::Suporte Técnico').parent).to eq(Group.find_by(name: 'LRI'))
    expect(Group.where(name: described_class.group_names('IRD')).count).to eq(3)
    expect(Group.find_by(name: 'Interno::TI')).to be_active
  end

  it 'creates the internal organizations without sharing, assigned by domain', :aggregate_failures do
    provisioning

    expect(Organization.find_by(name: 'LRI Automação Industrial')).to have_attributes(shared: false, domain: 'lri.com.br', domain_assignment: true)
    expect(Organization.find_by(name: 'IRD Produtos de Informática')).to have_attributes(shared: false, domain: 'ird.net.br')
  end

  it 'gives each agent role the agent permissions and full access to its own brand only', :aggregate_failures do
    provisioning

    role = Role.find_by(name: 'Agente IRD.Net')
    expect(role.permissions.pluck(:name)).to match_array(described_class::AGENT_PERMISSIONS)
    expect(role.group_names_access_map).to eq('IRD' => ['full'], 'IRD::Suporte' => ['full'], 'IRD::Comercial' => ['full'])
    expect(role.default_at_signup).to be(false)
  end

  it 'shows the default ticket overviews to the brand roles' do
    provisioning

    overview = Overview.joins(:roles).find_by(roles: { name: 'Agent' })
    expect(overview.roles.pluck(:name)).to include(*described_class::AGENT_ROLES.keys)
  end

  it 'offers customers only the brand queues, never the internal ones' do
    provisioning

    names = Group.where(id: Setting.get('customer_ticket_create_group_ids')).pluck(:name)
    expect(names).to match_array(['LRI::Suporte Técnico', 'LRI::Comercial', 'LRI::Financeiro', 'MW::Suporte', 'IRD::Suporte', 'IRD::Comercial'])
  end

  it 'changes nothing on a second run' do
    described_class.apply!

    expect(described_class.apply!).not_to be_changed
  end

  it 'turns sharing off again on an existing internal organization', :aggregate_failures do
    organization = create(:organization, name: 'LRI Automação Industrial', domain: 'lri.com.br', domain_assignment: true)
    organization.update_column(:shared, true) # rubocop:disable Rails/SkipsModelValidations

    expect(result_for(provisioning, 'LRI Automação Industrial')).to have_attributes(action: :updated, detail: 'shared')
    expect(organization.reload.shared).to be(false)
  end

  it 'reactivates a provisioned group that was deactivated' do
    described_class.apply!
    Group.find_by(name: 'MW::Suporte').update!(active: false)

    expect(result_for(described_class.apply!, 'MW::Suporte')).to have_attributes(action: :updated, detail: 'reativado')
  end

  it 'takes extra permissions away from an existing agent role and says which', :aggregate_failures do
    described_class.apply!
    Role.find_by(name: 'Agente LRI').permission_grant('admin.user')

    result = result_for(described_class.apply!, 'Agente LRI')
    expect(result.action).to eq(:updated)
    expect(result.detail).to include('-admin.user')
    expect(Role.find_by(name: 'Agente LRI').permissions.pluck(:name)).not_to include('admin.user')
  end

  it 'reactivates an inactive agent role and then leaves it alone', :aggregate_failures do
    described_class.apply!
    Role.find_by(name: 'Agente Interno').update!(active: false)

    expect(result_for(described_class.apply!, 'Agente Interno').detail).to include('reativado')
    expect(described_class.apply!).not_to be_changed
  end

  it 'names the queues it removes from the customer list' do
    described_class.apply!
    Setting.set('customer_ticket_create_group_ids', Group.where(name: ['Interno::TI', 'MW::Suporte']).pluck(:id).map(&:to_s))

    expect(result_for(described_class.apply!, 'customer_ticket_create_group_ids').detail).to include('-Interno::TI')
  end

  it 'reports a name taken in another letter case and writes nothing', :aggregate_failures do
    create(:group, name: 'lri')

    expect(provisioning).to be_conflicts
    expect(result_for(provisioning, 'LRI')).to have_attributes(action: :conflict)
    expect(Group.find_by(name: 'LRI::Comercial')).to be_nil
  end

  it 'writes nothing in a dry run, but reports what it would do', :aggregate_failures do
    run = described_class.apply!(dry_run: true)

    expect(run).to be_changed
    expect(Group.find_by(name: 'LRI')).to be_nil
  end

  it 'warns when another organization is assigned the same domain' do
    create(:organization, name: 'Outra', domain: 'ird.net.br', domain_assignment: true)

    expect(provisioning.results).to include(have_attributes(name: 'IRD Produtos de Informática', action: :warning))
  end
end
