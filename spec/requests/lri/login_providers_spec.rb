# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# A tela de login da zona pública não recebe os provedores de terceiros, que a guarda de zona recusa ali
# (docs/lri/esteira/login-zona/ux-spec-v1.yaml).
RSpec.describe 'Grupo LRI login providers per zone', type: :request do
  let(:application_config) { '{ applicationConfig { key value } }' }

  before do
    Setting.set('auth_google_oauth2', true)
    Setting.set('auth_microsoft_office365', true)
  end

  def legacy_config(headers = {})
    get '/api/v1/signshow', headers: headers, as: :json
    response.parsed_body['config']
  end

  def graphql_config(headers = {})
    post '/graphql', params: { query: application_config }, headers: headers, as: :json
    response.parsed_body.dig('data', 'applicationConfig').to_h { |entry| [entry['key'], entry['value']] }
  end

  context 'when the guard is off (upstream behaviour)' do
    it 'shows the enabled providers', :aggregate_failures do
      expect(legacy_config).to include('auth_google_oauth2' => true, 'auth_microsoft_office365' => true)
      expect(graphql_config).to include('auth_google_oauth2' => true, 'auth_microsoft_office365' => true)
    end
  end

  context 'when the guard is enforced' do
    before { enforce_lri_zone_guard }

    it 'hides every third-party provider from the public login', :aggregate_failures do
      Setting.set('auth_sso', true)

      expect(legacy_config.keys & Lri::ZoneGuard::PUBLIC_HIDDEN_SETTINGS).to be_empty
      expect(graphql_config.keys & Lri::ZoneGuard::PUBLIC_HIDDEN_SETTINGS).to be_empty
    end

    it 'sends the providers as boolean false to a signed-in customer' do
      customer = create(:customer, password: 'Senha-Forte-123')
      post '/api/v1/signin', params: { username: customer.login, password: 'Senha-Forte-123', fingerprint: '123456789' }, as: :json

      expect(legacy_config.slice('auth_google_oauth2', 'auth_microsoft_office365')).to eq('auth_google_oauth2' => false, 'auth_microsoft_office365' => false)
    end

    it 'keeps the rest of the public configuration' do
      expect(legacy_config).to include('product_name' => Setting.get('product_name'))
    end

    it 'shows the enabled providers on the internal login', :aggregate_failures do
      expect(legacy_config(lri_internal_headers)).to include('auth_google_oauth2' => true, 'auth_microsoft_office365' => true)
      expect(graphql_config(lri_internal_headers)).to include('auth_google_oauth2' => true, 'auth_microsoft_office365' => true)
    end
  end
end
