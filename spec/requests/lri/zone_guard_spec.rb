# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Guarda de zona do Grupo LRI (docs/lri/PLANO.md, seção 2.9.3): um teste negativo por caso de abuso.
RSpec.describe 'Grupo LRI zone guard', type: :request do
  let(:agent)    { create(:agent, password: 'Senha-Forte-123') }
  let(:admin)    { create(:admin, password: 'Senha-Forte-123') }
  let(:customer) { create(:customer, password: 'Senha-Forte-123') }

  def sign_in(user, headers = {})
    post '/api/v1/signin', params: { username: user.login, password: 'Senha-Forte-123', fingerprint: '123456789' }, headers: headers, as: :json
  end

  def me(headers = {})
    get '/api/v1/users/me', headers: headers, as: :json
  end

  context 'when the guard is off (upstream behaviour)' do
    it 'lets an agent sign in without any zone header' do
      sign_in(agent)

      expect(response).to have_http_status(:created)
    end
  end

  context 'when the guard is enforced' do
    before { enforce_lri_zone_guard }

    describe 'public zone' do
      it 'refuses an agent password login and does not keep the session', :aggregate_failures do
        sign_in(agent)

        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body).to include('error' => 'zone_restricted', 'internal_url' => LriZoneHelper::LRI_INTERNAL_URL)

        me
        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses an admin password login' do
        sign_in(admin)

        expect(response).to have_http_status(:forbidden)
      end

      it 'lets a customer sign in and stamps the session with the public zone', :aggregate_failures do
        sign_in(customer)

        expect(response).to have_http_status(:created)
        expect(session[:lri_zone]).to eq('public')

        me
        expect(response).to have_http_status(:ok)
      end

      it 'refuses basic authentication, even for a customer' do
        get '/api/v1/users/me', headers: { 'Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials(customer.login, 'Senha-Forte-123') }, as: :json

        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses an API token of an agent' do
        token = create(:token, user: agent, permissions: %w[ticket.agent])
        get '/api/v1/tickets', headers: { 'Authorization' => "Token token=#{token.token}" }, as: :json

        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses impersonation headers' do
        sign_in(customer)
        get '/api/v1/users/me', headers: { 'X-On-Behalf-Of' => agent.login }, as: :json

        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses header SSO with Remote-User' do
        get '/auth/sso', headers: { 'Remote-User' => customer.login }

        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses the staff third-party login paths, in any letter case' do
        %w[/auth/google_oauth2 /AUTH/Microsoft_Office365/callback/ /oauth/token].each do |path|
          get path

          expect(response).to have_http_status(:forbidden), "#{path} should be refused"
        end
      end

      it 'answers browser navigation with the pt-BR block page', :aggregate_failures do
        get '/auth/google_oauth2', headers: { 'Accept' => 'text/html' }

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include('Acesso da equipe só pelo endereço interno', LriZoneHelper::LRI_INTERNAL_URL)
      end
    end

    describe 'forged or incomplete internal zone' do
      it 'treats X-LRI-Zone without the zone key as public' do
        sign_in(agent, { 'X-LRI-Zone' => 'internal' })

        expect(response).to have_http_status(:forbidden)
      end

      it 'treats a wrong zone key as public' do
        sign_in(agent, lri_internal_headers(key: 'x' * 40))

        expect(response).to have_http_status(:forbidden)
      end

      it 'treats a missing Access JWT as public' do
        sign_in(agent, lri_internal_headers(jwt: nil))

        expect(response).to have_http_status(:forbidden)
      end

      it 'treats an Access JWT for another application as public' do
        sign_in(agent, lri_internal_headers(jwt: lri_access_jwt(aud: 'outro-aplicativo')))

        expect(response).to have_http_status(:forbidden)
      end

      it 'treats an expired Access JWT as public' do
        sign_in(agent, lri_internal_headers(jwt: lri_access_jwt(exp: 1.minute.ago)))

        expect(response).to have_http_status(:forbidden)
      end

      it 'treats an Access JWT signed by another key as public' do
        sign_in(agent, lri_internal_headers(jwt: lri_access_jwt(key: OpenSSL::PKey::RSA.generate(2048))))

        expect(response).to have_http_status(:forbidden)
      end

      it 'treats a zone header with different casing of the value as public' do
        sign_in(agent, lri_internal_headers.merge('X-LRI-Zone' => 'Internal'))

        expect(response).to have_http_status(:forbidden)
      end
    end

    describe 'internal zone' do
      it 'lets an agent sign in and stamps the session with the internal zone', :aggregate_failures do
        sign_in(agent, lri_internal_headers)

        expect(response).to have_http_status(:created)
        expect(session[:lri_zone]).to eq('internal')

        me(lri_internal_headers)
        expect(response).to have_http_status(:ok)
      end

      it 'refuses the same agent session when it is replayed on the public zone' do
        sign_in(agent, lri_internal_headers)
        me

        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses a customer session born in the internal zone when replayed on the public zone' do
        sign_in(customer, lri_internal_headers)
        me

        expect(response).to have_http_status(:forbidden)
      end

      it 'refuses a switched session ("entrar como") on the public zone', :aggregate_failures do
        sign_in(admin, lri_internal_headers)
        get "/api/v1/sessions/switch/#{customer.id}", headers: lri_internal_headers, as: :json
        expect(response).to have_http_status(:ok)

        me
        expect(response).to have_http_status(:forbidden)
      end
    end
  end
end
