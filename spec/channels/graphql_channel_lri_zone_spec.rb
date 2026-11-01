# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Guarda de zona do Grupo LRI no ActionCable.
RSpec.describe GraphqlChannel, type: :channel do
  let(:user)  { create(:customer) }
  let(:query) { 'query { currentUser { id } }' }

  before { enforce_lri_zone_guard }

  context 'when the public connection belongs to a customer' do
    it 'executes the operation' do
      stub_connection sid: '123_456', current_user: user, lri_zone: 'public'
      subscribe

      perform :execute, query: query

      expect(transmissions.last).to include(result: include(data: include(currentUser: include(id: user.to_global_id.to_s))))
    end
  end

  context 'when the customer of a public connection is promoted to agent' do
    it 'closes the connection instead of executing', :aggregate_failures do
      stub_connection sid: '123_456', current_user: user, lri_zone: 'public'
      subscribe
      # O ConnectionStub do Rails não tem #close; a conexão real tem (ActionCable::Connection::Base#close).
      close_calls = []
      connection.define_singleton_method(:close) { |**options| close_calls << options }

      user.update!(roles: Role.where(name: 'Agent'))
      perform :execute, query: query

      expect(close_calls).to contain_exactly(hash_including(reconnect: true))
      expect(transmissions).to be_empty
    end
  end

  context 'when the same agent uses an internal connection' do
    it 'executes the operation' do
      user.update!(roles: Role.where(name: 'Agent'))
      stub_connection sid: '123_456', current_user: user, lri_zone: 'internal'
      subscribe

      perform :execute, query: query

      expect(transmissions.last).to include(result: include(data: include(currentUser: include(id: user.to_global_id.to_s))))
    end
  end
end
