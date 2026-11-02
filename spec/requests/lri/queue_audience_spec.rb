# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Filas por público pela API (Lri::QueueAudience e os workflows do provisionamento).
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
  end

  it 'accepts an outsider in a brand queue over REST' do
    expect { rest_create(outsider, brand_queue) }.to change(Ticket, :count).by(1)
  end

  it 'refuses a collaborator in a brand queue over REST' do
    expect { rest_create(collaborator, brand_queue) }.not_to change(Ticket, :count)
  end

  it 'accepts a collaborator in an internal queue over REST' do
    expect { rest_create(collaborator, internal_queue) }.to change(Ticket, :count).by(1)
  end

  it 'refuses an outsider in an internal queue over GraphQL', :aggregate_failures do
    expect { graphql_create_as(outsider, internal_queue) }.not_to change(Ticket, :count)
    expect(response.parsed_body.dig('data', 'ticketCreate', 'ticket')).to be_nil
  end

  it 'accepts a collaborator in an internal queue over GraphQL' do
    expect { graphql_create_as(collaborator, internal_queue) }.to change(Ticket, :count).by(1)
  end

  it 'tells the customer why when only the server rule refuses' do
    CoreWorkflow.where(name: [Lri::Provisioning::INTERNAL_QUEUES_WORKFLOW]).update_all(active: false)

    rest_create(outsider, internal_queue)
    expect(response.parsed_body['error']).to eq(Lri::QueueAudience::MESSAGE)
  end
end
