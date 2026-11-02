# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::Provisioning do
  subject(:provisioning) { described_class.apply! }

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

    organization = Organization.find_by(name: 'LRI Automação Industrial')
    expect(organization).to have_attributes(shared: false, domain: 'lri.com.br', domain_assignment: true)
    expect(Organization.find_by(name: 'IRD Produtos de Informática')).to have_attributes(shared: false, domain: 'ird.net.br')
  end

  it 'gives each agent role full access to its own brand only', :aggregate_failures do
    provisioning

    role = Role.find_by(name: 'Agente IRD.Net')
    expect(role.permission_ids).to match_array(Role.find_by(name: 'Agent').permission_ids)
    expect(role.group_names_access_map.keys).to match_array(%w[IRD IRD::Suporte IRD::Comercial])
    expect(Role.find_by(name: 'Agente Mean Well Brasil').group_names_access_map.keys).to match_array(%w[MW MW::Suporte])
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
    create(:organization, name: 'LRI Automação Industrial', shared: true)

    result = provisioning.results.find { |entry| entry.name == 'LRI Automação Industrial' }
    expect(result.action).to eq(:updated)
    expect(Organization.find_by(name: 'LRI Automação Industrial').shared).to be(false)
  end

  it 'reactivates a provisioned group that was deactivated' do
    described_class.apply!
    Group.find_by(name: 'MW::Suporte').update!(active: false)

    expect(described_class.apply!.results).to include(have_attributes(name: 'MW::Suporte', action: :updated))
  end
end
