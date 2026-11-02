# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Filas por público pela API (Lri::QueueAudience).
RSpec.describe 'Grupo LRI queue audience', type: :request do
  let(:internal_queue) { Group.find_by(name: 'Interno::TI') }
  let(:brand_queue)    { Group.find_by(name: 'LRI::Comercial') }
  let(:outsider)       { create(:customer) }
  let(:collaborator)   { create(:customer, organization: Organization.find_by(name: 'LRI Automação Industrial')) }

  let(:graphql_create) do
    <<~GRAPHQL
      mutation ticketCreate($input: TicketCreateInput!) {
        ticketCreate(input: $input) { ticket { id } errors { message field } }
      }
    GRAPHQL
  end

  before { Lri::Provisioning.apply! }

  def rest_create(user, group)
    authenticated_as(user)
    post '/api/v1/tickets', params: { title: 'Chamado', group: group.name, article: { body: 'Texto' } }, as: :json
  end

  def graphql_create_as(user, group)
    authenticated_as(user)
    input = { title: 'Chamado', groupId: Gql::ZammadSchema.id_from_object(group), article: { body: 'Texto' } }
    post '/graphql', params: { query: graphql_create, variables: { input: input } }, as: :json
  end

  it 'refuses an outsider in an internal queue over REST', :aggregate_failures do
    expect { rest_create(outsider, internal_queue) }.not_to change(Ticket, :count)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq(Lri::QueueAudience::MESSAGE)
  end

  it 'logs the structured reason of a refusal' do
    allow(Rails.logger).to receive(:warn)
    rest_create(outsider, internal_queue)

    expect(Rails.logger).to have_received(:warn).with(%r{Lri::QueueAudience: recusado reason=queue_audience user=#{outsider.id} group=#{internal_queue.id}})
  end

  it 'accepts an outsider in a brand queue over REST' do
    expect { rest_create(outsider, brand_queue) }.to change(Ticket, :count).by(1)
  end

  it 'refuses a collaborator in a brand queue over REST', :aggregate_failures do
    expect { rest_create(collaborator, brand_queue) }.not_to change(Ticket, :count)
    expect(response.parsed_body['error']).to eq(Lri::QueueAudience::MESSAGE)
  end

  it 'accepts a collaborator in an internal queue over REST' do
    expect { rest_create(collaborator, internal_queue) }.to change(Ticket, :count).by(1)
  end

  def graphql_error
    response.parsed_body.dig('errors', 0, 'message').to_s
  end

  it 'refuses an outsider in an internal queue over GraphQL, because of the group', :aggregate_failures do
    expect { graphql_create_as(outsider, internal_queue) }.not_to change(Ticket, :count)
    expect(graphql_error).to eq(Lri::QueueAudience::MESSAGE)
  end

  it 'refuses a collaborator in a brand queue over GraphQL, because of the group', :aggregate_failures do
    expect { graphql_create_as(collaborator, brand_queue) }.not_to change(Ticket, :count)
    expect(graphql_error).to eq(Lri::QueueAudience::MESSAGE)
  end

  it 'accepts an outsider in a brand queue over GraphQL' do
    expect { graphql_create_as(outsider, brand_queue) }.to change(Ticket, :count).by(1)
  end

  it 'accepts a collaborator in an internal queue over GraphQL' do
    expect { graphql_create_as(collaborator, internal_queue) }.to change(Ticket, :count).by(1)
  end

  context 'when a workflow leaves an outsider no brand queue' do
    before do
      brand_ids = Group.where(name: Lri::Provisioning.customer_group_names).where.not(id: Lri::QueueAudience.internal_groups).pluck(:id).map(&:to_s)
      create(:core_workflow, :active_and_screen, screen: 'create_middle', object: 'Ticket',
             perform: { 'ticket.group_id' => { 'operator' => 'remove_option', 'remove_option' => brand_ids } })
    end

    it 'refuses the ticket over REST' do
      expect { rest_create(outsider, brand_queue) }.not_to change(Ticket, :count)
    end

    it 'refuses the ticket over GraphQL' do
      expect { graphql_create_as(outsider, brand_queue) }.not_to change(Ticket, :count)
    end
  end

  it 'refuses moving a collaborator ticket into a brand queue over REST and keeps the queue', :aggregate_failures do
    rest_create(collaborator, internal_queue)
    ticket = Ticket.last

    put "/api/v1/tickets/#{ticket.id}", params: { group: brand_queue.name }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body['error']).to eq(Lri::QueueAudience::MESSAGE)
    expect(ticket.reload.group).to eq(internal_queue)
  end
end
