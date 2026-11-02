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

  it 'lists every queue for the portal, each customer seeing only those of their audience' do
    provisioning

    names = Group.where(id: Setting.get('customer_ticket_create_group_ids')).pluck(:name)
    expect(names).to contain_exactly('LRI::Suporte Técnico', 'LRI::Comercial', 'LRI::Financeiro', 'MW::Suporte', 'IRD::Suporte',
                                     'IRD::Comercial', 'Interno::TI', 'Interno::Administrativo')
  end

  describe 'internal queues' do
    let(:internal_queue) { Group.find_by(name: 'Interno::TI') }
    let(:brand_queue)    { Group.find_by(name: 'LRI::Comercial') }

    before { described_class.apply! }

    def create_ticket_as(customer, group)
      UserInfo.with_user_id(customer.id) do
        Ticket.create!(title: 'Chamado', group: group, customer: customer, screen: 'create_middle')
      end
    end

    def offered_group_ids(customer)
      result = CoreWorkflow.perform(payload: { 'event' => 'core_workflow', 'request_id' => 'teste', 'class_name' => 'Ticket',
                                               'screen' => 'create_middle', 'params' => {} }, user: customer, assets: false)
      result[:restrict_values]['group_id'].map(&:to_s)
    end

    it 'refuses a ticket in an internal queue from a customer outside the group' do
      expect { create_ticket_as(create(:customer), internal_queue) }.to raise_error(Exceptions::UnprocessableContent)
    end

    it 'refuses it also from a customer of another company' do
      outsider = create(:customer, organization: create(:organization, name: 'Cliente Externo'))

      expect { create_ticket_as(outsider, internal_queue) }.to raise_error(Exceptions::UnprocessableContent)
    end

    it 'accepts a ticket in a brand queue from a customer outside the group' do
      expect { create_ticket_as(create(:customer), brand_queue) }.to change(Ticket, :count).by(1)
    end

    it 'accepts a ticket in an internal queue from a collaborator of an internal organization' do
      collaborator = create(:customer, organization: Organization.find_by(name: 'IRD Produtos de Informática'))

      expect { create_ticket_as(collaborator, internal_queue) }.to change(Ticket, :count).by(1)
    end

    it 'refuses a ticket in a brand queue from a collaborator' do
      collaborator = create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial'))

      expect { create_ticket_as(collaborator, brand_queue) }.to raise_error(Exceptions::UnprocessableContent)
    end

    it 'shows the brand queues to outsiders and the internal queues to collaborators', :aggregate_failures do
      collaborator = create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial'))
      outsider     = create(:customer)

      expect(offered_group_ids(outsider)).to include(brand_queue.id.to_s)
      expect(offered_group_ids(outsider)).not_to include(internal_queue.id.to_s)
      expect(offered_group_ids(collaborator)).to include(internal_queue.id.to_s)
      expect(offered_group_ids(collaborator)).not_to include(brand_queue.id.to_s)
    end

    it 'keeps both audiences apart when an earlier workflow stops the chain', :aggregate_failures do
      create(:core_workflow, :active_and_screen, screen: 'create_middle', object: 'Ticket', priority: 0, stop_after_match: true)
      collaborator = create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial'))
      outsider     = create(:customer)

      expect(offered_group_ids(outsider)).not_to include(internal_queue.id.to_s)
      expect(offered_group_ids(collaborator)).not_to include(brand_queue.id.to_s)
      expect { create_ticket_as(outsider, internal_queue) }.to raise_error(Exceptions::UnprocessableContent)
      expect { create_ticket_as(collaborator, brand_queue) }.to raise_error(Exceptions::UnprocessableContent)
    end

    it 'does not let a workflow add a queue of the other audience back', :aggregate_failures do
      create(:core_workflow, :active_and_screen, screen: 'create_middle', object: 'Ticket',
             perform: { 'ticket.group_id' => { 'operator' => 'add_option', 'add_option' => [internal_queue.id.to_s, brand_queue.id.to_s] } })
      collaborator = create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial'))
      outsider     = create(:customer)

      expect(offered_group_ids(outsider)).to include(brand_queue.id.to_s)
      expect(offered_group_ids(outsider)).not_to include(internal_queue.id.to_s)
      expect(offered_group_ids(collaborator)).to include(internal_queue.id.to_s)
      expect(offered_group_ids(collaborator)).not_to include(brand_queue.id.to_s)
    end

    it 'drops a forbidden queue that a workflow adds, selects and hides, and gives the field back', :aggregate_failures do
      create(:core_workflow, :active_and_screen, screen: 'create_middle', object: 'Ticket',
             perform: { 'ticket.group_id' => { 'operator' => %w[add_option select hide set_readonly], 'add_option' => [internal_queue.id.to_s],
                                               'select' => [internal_queue.id.to_s], 'hide' => true, 'set_readonly' => true } })
      outsider = create(:customer)

      result = CoreWorkflow.perform(payload: { 'event' => 'core_workflow', 'request_id' => 'teste', 'class_name' => 'Ticket',
                                               'screen' => 'create_middle', 'params' => {} }, user: outsider, assets: false)

      expect(Array(result.dig(:select, 'group_id')).map(&:to_s)).not_to include(internal_queue.id.to_s)
      expect(result[:restrict_values]['group_id'].map(&:to_s)).not_to include(internal_queue.id.to_s)
      expect(result[:restrict_values]['group_id'].map(&:to_s)).to include(brand_queue.id.to_s)
      expect(result[:visibility]['group_id']).to eq('show')
      expect(result[:readonly]['group_id']).to be(false)
      expect { create_ticket_as(outsider, brand_queue) }.to change(Ticket, :count).by(1)
    end

    it 'gives each audience its own queues back when a workflow fixes the field to the other audience', :aggregate_failures do
      create(:core_workflow, :active_and_screen, screen: 'create_middle', object: 'Ticket',
             perform: { 'ticket.group_id' => { 'operator' => %w[set_fixed_to hide set_readonly], 'set_fixed_to' => [internal_queue.id.to_s],
                                               'hide' => true, 'set_readonly' => true } })
      outsider = create(:customer)

      result = CoreWorkflow.perform(payload: { 'event' => 'core_workflow', 'request_id' => 'teste', 'class_name' => 'Ticket',
                                               'screen' => 'create_middle', 'params' => {} }, user: outsider, assets: false)

      expect(result[:restrict_values]['group_id'].map(&:to_s)).to include(brand_queue.id.to_s)
      expect(result[:restrict_values]['group_id'].map(&:to_s)).not_to include(internal_queue.id.to_s)
      expect(result[:visibility]['group_id']).to eq('show')
      expect(result[:readonly]['group_id']).to be(false)
    end

    it 'treats an internal queue created after provisioning as internal on the server' do
      new_queue = create(:group, name: 'Interno::RH')

      expect(Lri::QueueAudience.denial(create(:customer), new_queue)).to eq('fila interna para cliente de fora')
    end

    it 'opens an internal queue created later to collaborators on the next run', :aggregate_failures do
      new_queue    = create(:group, name: 'Interno::RH')
      collaborator = create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial'))

      expect(result_for(described_class.apply!, 'customer_ticket_create_group_ids').detail).to include('+Interno::RH')
      expect { create_ticket_as(create(:customer), new_queue) }.to raise_error(Exceptions::UnprocessableContent)
      expect { create_ticket_as(collaborator, new_queue) }.to change(Ticket, :count).by(1)
    end

    it 'refuses moving an outsider ticket into an internal queue and keeps the group', :aggregate_failures do
      outsider = create(:customer)
      ticket   = create_ticket_as(outsider, brand_queue)

      expect do
        UserInfo.with_user_id(outsider.id) { ticket.update!(group: internal_queue, screen: 'edit') }
      end.to raise_error(Exceptions::UnprocessableContent)
      expect(ticket.reload.group).to eq(brand_queue)
    end

    it 'keeps a collaborator out of the brand queues even if the internal root group is renamed', :aggregate_failures do
      collaborator = create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial'))
      ticket       = create_ticket_as(collaborator, internal_queue)
      Group.find_by(name: 'Interno').update!(name: 'Apoio')

      expect do
        UserInfo.with_user_id(collaborator.id) { ticket.update!(group: brand_queue, screen: 'edit') }
      end.to raise_error(Exceptions::UnprocessableContent, Lri::QueueAudience::MESSAGE)
      expect(ticket.reload.group_id).to eq(internal_queue.id)
    end

    it 'keeps outsiders out of the internal queues after the root group is renamed', :aggregate_failures do
      Group.find_by(name: 'Interno').update!(name: 'Apoio')
      outsider = create(:customer)

      expect(offered_group_ids(outsider)).not_to include(internal_queue.id.to_s)
      expect { create_ticket_as(outsider, internal_queue.reload) }.to raise_error(Exceptions::UnprocessableContent, Lri::QueueAudience::MESSAGE)
      expect(Lri::QueueAudience.denial(outsider, internal_queue)).to eq('grupo Interno ausente numa instalação provisionada')
    end

    it 'lets an existing ticket be edited when its group does not change' do
      outsider = create(:customer)
      ticket   = UserInfo.with_user_id(outsider.id) { Ticket.create!(title: 'Por e-mail', group: internal_queue, customer: outsider) }

      expect { UserInfo.with_user_id(outsider.id) { ticket.update!(title: 'Novo título', screen: 'edit') } }.not_to raise_error
    end

    it 'leaves a collaborator who is also an agent free to use the brand queues', :aggregate_failures do
      both = create(:agent, groups: [brand_queue], organization: Organization.find_by(name: 'LRI Automação Industrial'))
      both.roles << Role.find_by(name: 'Customer')

      expect(offered_group_ids(both)).to include(brand_queue.id.to_s)
      expect { create_ticket_as(both, brand_queue) }.to change(Ticket, :count).by(1)
    end

    it 'does not touch tickets created without a screen, such as incoming e-mail' do
      outsider = create(:customer)

      expect do
        UserInfo.with_user_id(outsider.id) { Ticket.create!(title: 'Por e-mail', group: internal_queue, customer: outsider) }
      end.to change(Ticket, :count).by(1)
    end

    it 'leaves agents alone' do
      agent = create(:agent, groups: [internal_queue, brand_queue])

      expect(offered_group_ids(agent)).to include(internal_queue.id.to_s, brand_queue.id.to_s)
    end
  end

  it 'changes nothing on a second run' do
    described_class.apply!

    expect(described_class.apply!).not_to be_changed
  end

  it 'turns sharing off again on an existing internal organization', :aggregate_failures do
    organization = create(:organization, name: 'LRI Automação Industrial', domain: 'lri.com.br', domain_assignment: true)
    organization.update_column(:shared, true)

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
    role = Role.find_by(name: 'Agente LRI')
    role.permission_grant('report')
    role.save!

    result = result_for(described_class.apply!, 'Agente LRI')
    expect(result.action).to eq(:updated)
    expect(result.detail).to include('-report')
    expect(role.reload.permissions.pluck(:name)).not_to include('report')
  end

  it 'reactivates an inactive agent role and then leaves it alone', :aggregate_failures do
    described_class.apply!
    Role.find_by(name: 'Agente Interno').update!(active: false)

    expect(result_for(described_class.apply!, 'Agente Interno').detail).to include('reativado')
    expect(described_class.apply!).not_to be_changed
  end

  it 'removes access to an inactive group of another brand', :aggregate_failures do
    described_class.apply!
    create(:group, name: 'Fila antiga')
    role = Role.find_by(name: 'Agente Mean Well Brasil')
    role.group_names_access_map = role.group_names_access_map.merge('Fila antiga' => ['full'])
    Group.find_by(name: 'Fila antiga').update!(active: false)

    expect(result_for(described_class.apply!, 'Agente Mean Well Brasil').detail).to include('-Fila antiga')
    expect(role.groups.access.pluck(:name)).not_to include('Fila antiga')
  end

  it 'names the queues it removes from the customer list' do
    described_class.apply!
    create(:group, name: 'Fila solta')
    Setting.set('customer_ticket_create_group_ids', Group.where(name: ['Fila solta', 'MW::Suporte']).pluck(:id).map(&:to_s))

    expect(result_for(described_class.apply!, 'customer_ticket_create_group_ids').detail).to include('-Fila solta')
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
    expect(Setting.get('timezone_default')).not_to eq('America/Sao_Paulo')
  end

  describe 'notifications to connected clients' do
    before do
      allow(Sessions).to receive(:broadcast)
      allow(Sessions).to receive(:send_to)
    end

    it 'announces the new groups after a real run' do
      described_class.apply!

      expect(Sessions).to have_received(:broadcast).with(hash_including(event: 'Group:create'), any_args).at_least(:once)
    end

    it 'does not announce the records when the enclosing transaction rolls back' do
      ActiveRecord::Base.transaction(requires_new: true) do
        described_class.apply!
        raise ActiveRecord::Rollback
      end

      expect(Sessions).not_to have_received(:broadcast).with(hash_including(event: 'Group:create'), any_args)
    end

    it 'does not announce the records of a dry run' do
      described_class.apply!(dry_run: true)

      expect(Sessions).not_to have_received(:broadcast).with(hash_including(event: 'Group:create'), any_args)
    end
  end

  it 'warns when another organization is assigned the same domain' do
    create(:organization, name: 'Outra', domain: 'ird.net.br', domain_assignment: true)

    expect(provisioning.results).to include(have_attributes(name: 'IRD Produtos de Informática', action: :warning))
  end
end
