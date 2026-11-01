# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Guarda de zona nos transportes de tempo real, que autenticam fora do fluxo Rack dos controllers.
RSpec.describe 'Grupo LRI zone guard on realtime transports' do # rubocop:disable RSpec/DescribeClass
  let(:session_id)     { SecureRandom.hex(16) }
  let(:session_cookie) { "#{Zammad::Application::Initializer::SessionStore::SESSION_KEY}=#{session_id}" }
  let(:origin)         { "#{Setting.get('http_type')}://#{Setting.get('fqdn')}" }
  let(:session_extra)  { {} }

  before do
    enforce_lri_zone_guard
    session = create(:active_session, session_id: Rack::Session::SessionId.new(session_id).private_id, user: user)
    session.update!(data: session.data.merge(session_extra)) if session_extra.present?
  end

  describe Sessions::Event::Login do
    subject(:run_event) do
      described_class.new(payload: { 'event' => 'login' }, headers: headers, client_id: 'c1', client: client).run
    end

    let(:client) { {} }

    before do
      allow(Sessions).to receive(:create)
      allow(Sessions).to receive(:send)
    end

    context 'with an agent session on the public zone' do
      let(:user)    { create(:agent) }
      let(:headers) { { 'Origin' => origin, 'Cookie' => session_cookie } }

      it 'starts an anonymous session' do
        run_event

        expect(client[:session]).to eq({})
      end
    end

    context 'with an agent session and a forged zone header' do
      let(:user)    { create(:agent) }
      let(:headers) { { 'Origin' => origin, 'Cookie' => session_cookie, 'X-LRI-Zone' => 'internal' } }

      it 'starts an anonymous session' do
        run_event

        expect(client[:session]).to eq({})
      end
    end

    context 'with an agent session on the internal zone' do
      let(:user)    { create(:agent) }
      let(:headers) { { 'Origin' => origin, 'Cookie' => session_cookie }.merge(lri_internal_headers) }

      it 'starts the agent session' do
        run_event

        expect(client[:session]).to eq({ 'id' => user.id })
      end
    end

    context 'with a customer session born in the internal zone, on the public zone' do
      let(:user)          { create(:customer) }
      let(:session_extra) { { 'lri_zone' => 'internal' } }
      let(:headers)       { { 'Origin' => origin, 'Cookie' => session_cookie } }

      it 'starts an anonymous session' do
        run_event

        expect(client[:session]).to eq({})
      end
    end

    context 'with a customer session on the public zone' do
      let(:user)    { create(:customer) }
      let(:headers) { { 'Origin' => origin, 'Cookie' => session_cookie } }

      it 'starts the customer session' do
        run_event

        expect(client[:session]).to eq({ 'id' => user.id })
      end
    end
  end

  describe ApplicationCable::Connection, type: :channel do
    before { cookies[Zammad::Application::Initializer::SessionStore::SESSION_KEY] = session_id }

    context 'with an agent session on the public zone' do
      let(:user) { create(:agent) }

      it 'connects without a user' do
        connect

        expect(connection.current_user).to be_nil
      end
    end

    context 'with an agent session on the internal zone' do
      let(:user) { create(:agent) }

      it 'connects as the agent' do
        connect headers: lri_internal_headers

        expect(connection.current_user).to eq(user)
      end
    end

    context 'with a customer session on the public zone' do
      let(:user) { create(:customer) }

      it 'connects as the customer' do
        connect

        expect(connection.current_user).to eq(user)
      end
    end

    context 'with an agent session and a forged zone header' do
      let(:user) { create(:agent) }

      it 'connects without a user' do
        connect headers: { 'X-LRI-Zone' => 'internal' }

        expect(connection.current_user).to be_nil
      end
    end

    context 'with a customer session born in the internal zone, on the public zone' do
      let(:user)          { create(:customer) }
      let(:session_extra) { { 'lri_zone' => 'internal' } }

      it 'connects without a user' do
        connect

        expect(connection.current_user).to be_nil
      end
    end

    context 'with a switched session on the public zone' do
      let(:user)          { create(:customer) }
      let(:session_extra) { { 'switched_from_user_id' => create(:admin).id } }

      it 'connects without a user' do
        connect

        expect(connection.current_user).to be_nil
      end
    end
  end

  context 'when the guard is off' do
    let(:user)    { create(:agent) }
    let(:headers) { { 'Origin' => origin, 'Cookie' => session_cookie } }

    before { allow(Lri::Zone::Config).to receive(:current).and_return(Lri::Zone::Config.new({})) }

    it 'keeps the upstream behaviour on the websocket' do
      allow(Sessions).to receive(:create)
      allow(Sessions).to receive(:send)
      client = {}
      Sessions::Event::Login.new(payload: { 'event' => 'login' }, headers: headers, client_id: 'c2', client: client).run

      expect(client[:session]).to eq({ 'id' => user.id })
    end
  end
end
