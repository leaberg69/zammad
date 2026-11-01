# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Guarda de zona do Grupo LRI (docs/lri/PLANO.md, seção 2.9.3): um teste negativo por caso de abuso. Toda recusa é
# conferida pelo corpo `zone_restricted` da guarda, para não confundir com um 403 do próprio Zammad.
RSpec.describe 'Grupo LRI zone guard', type: :request do
  let(:password) { 'Senha-Forte-123' }
  let(:agent)    { create(:agent, password: password) }
  let(:admin)    { create(:admin, password: password) }
  let(:customer) { create(:customer, password: password) }

  let(:login_mutation) do
    <<~GRAPHQL
      mutation login($input: LoginInput!) {
        login(input: $input) { session { id } errors { message } }
      }
    GRAPHQL
  end

  def sign_in(user, headers = {})
    post '/api/v1/signin', params: { username: user.login, password: password, fingerprint: '123456789' }, headers: headers, as: :json
  end

  def graphql_sign_in(user, headers = {})
    post '/graphql', params: { query: login_mutation, variables: { input: { login: user.login, password: password } } },
                     headers: headers.merge('X-Browser-Fingerprint' => '123456789'), as: :json
  end

  def me(headers = {})
    get '/api/v1/users/me', headers: headers, as: :json
  end

  def current_session_record
    ActiveRecord::SessionStore::Session.find_by(session_id: Rack::Session::SessionId.new(cookies[Zammad::Application::Initializer::SessionStore::SESSION_KEY].to_s).private_id)
  end

  def expect_zone_denied
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to include('error' => 'zone_restricted', 'internal_url' => LriZoneHelper::LRI_INTERNAL_URL)
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
      it 'refuses an agent password login and discards the session', :aggregate_failures do
        sign_in(agent)
        expect_zone_denied
        expect(session[:user_id]).to be_nil

        me
        expect(response).to have_http_status(:forbidden)
        expect(response.parsed_body['error']).not_to eq('zone_restricted') # anônimo, recusado pelo próprio Zammad
      end

      it 'refuses an admin password login', :aggregate_failures do
        sign_in(admin)

        expect_zone_denied
      end

      it 'refuses an agent GraphQL login and discards the session', :aggregate_failures do
        graphql_sign_in(agent)

        expect_zone_denied
        expect(session[:user_id]).to be_nil
      end

      # Revisão Codex (PR #1): numa operação só, login → ação privilegiada → logout. Sem o ponto de checagem em
      #   current_user_set, a ação rodava como agente e o logout escondia a sessão da pós-checagem.
      it 'refuses an agent GraphQL login chained with a privileged action and a logout', :aggregate_failures do
        chain = <<~GRAPHQL
          mutation chain($input: LoginInput!, $token: UserAccessTokenInput!) {
            login(input: $input) { session { id } }
            userCurrentAccessTokenAdd(input: $token) { tokenValue }
            logout { success }
          }
        GRAPHQL

        variables = {
          input: { login: agent.login, password: password },
          token: { name: 'roubado', permission: ['ticket.agent'] },
        }

        expect do
          post '/graphql', params: { query: chain, variables: variables }, headers: { 'X-Browser-Fingerprint' => '123456789' }, as: :json
        end.not_to change(Token, :count)

        expect_zone_denied
        expect(response.body).not_to include('tokenValue')
      end

      it 'lets a customer GraphQL login through and stamps it with the public zone', :aggregate_failures do
        graphql_sign_in(customer)

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig('data', 'login', 'session', 'id')).to be_present
        expect(session[:lri_zone]).to eq('public')
      end

      it 'lets a customer sign in and stamps the session with the public zone', :aggregate_failures do
        sign_in(customer)

        expect(response).to have_http_status(:created)
        expect(session[:lri_zone]).to eq('public')

        me
        expect(response).to have_http_status(:ok)
      end

      it 'refuses basic authentication, even for a customer' do
        get '/api/v1/users/me', headers: { 'Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials(customer.login, password) }, as: :json

        expect_zone_denied
      end

      it 'refuses an API token of an agent' do
        token = create(:token, user: agent, permissions: %w[ticket.agent])
        get '/api/v1/tickets', headers: { 'Authorization' => "Token token=#{token.token}" }, as: :json

        expect_zone_denied
      end

      it 'refuses an OAuth2 bearer token' do
        get '/api/v1/users/me', headers: { 'Authorization' => 'Bearer abc123' }, as: :json

        expect_zone_denied
      end

      it 'refuses header SSO (Remote-User and X-Forwarded-User)', :aggregate_failures do
        get '/api/v1/users/me', headers: { 'Remote-User' => customer.login }, as: :json
        expect_zone_denied

        get '/api/v1/users/me', headers: { 'X-Forwarded-User' => customer.login }, as: :json
        expect_zone_denied
      end

      it 'refuses the staff paths in any letter case and with repeated slashes', :aggregate_failures do
        %w[/auth/sso /auth/google_oauth2 /AUTH/Microsoft_Office365/callback/ /oauth/token //oauth/token
           /api/v1/external_credentials/google/link_account /api/v1/monitoring/health_check].each do |path|
          get path, as: :json

          expect(response.parsed_body['error']).to eq('zone_restricted'), "#{path} should be refused by the guard"
        end
      end

      it 'answers browser navigation with the pt-BR block page', :aggregate_failures do
        get '/auth/google_oauth2', headers: { 'Accept' => 'text/html' }

        expect(response).to have_http_status(:forbidden)
        expect(response.headers['Cache-Control']).to include('no-store')
        expect(response.body).to include('Acesso da equipe só pelo endereço interno', LriZoneHelper::LRI_INTERNAL_URL)
      end

      it 'still answers a malformed Content-Type with the structured refusal' do
        post '/oauth/token', params: 'x', headers: { 'Content-Type' => 'not a mime/type;;' }

        expect(response).to have_http_status(:forbidden)
      end

      # Revisão Codex (PR #1): token de prévia da KB de um agente autenticava sem passar por current_user_set.
      it 'refuses a staff knowledge base preview token and clears it from the session', :aggregate_failures do
        create(:knowledge_base)
        token = create(:token, action: 'KnowledgeBasePreview', user: agent)

        get "/help?preview_token=#{token.token}", headers: { 'Accept' => 'text/html' }

        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include('Acesso da equipe só pelo endereço interno')
        expect(session[:kb_preview_token]).to be_nil
      end

      # Revisão Codex (PR #1): feed da KB com ?token= de um admin servia respostas internas sem sessão.
      it 'refuses a staff knowledge base feed token in the URL, for root and category feeds', :aggregate_failures do
        knowledge_base = create(:knowledge_base)
        category       = create(:knowledge_base_category, knowledge_base: knowledge_base)
        locale         = knowledge_base.kb_locales.first.system_locale.locale
        token          = Token.ensure_token!('KnowledgeBaseFeed', admin.id)

        get feed_knowledge_base_path(knowledge_base, locale, token: token)
        expect(response.parsed_body['error']).to eq('zone_restricted')

        get feed_knowledge_base_category_path(knowledge_base, category, locale, token: token)
        expect(response.parsed_body['error']).to eq('zone_restricted')
      end

      it 'refuses a staff feed token hidden behind a repeated parameter' do
        knowledge_base = create(:knowledge_base)
        locale         = knowledge_base.kb_locales.first.system_locale.locale
        token          = Token.ensure_token!('KnowledgeBaseFeed', admin.id)

        get "#{feed_knowledge_base_path(knowledge_base, locale)}?token=qualquer&token=#{token}"

        expect(response.parsed_body['error']).to eq('zone_restricted')
      end

      it 'serves the same feed token on the internal zone' do
        knowledge_base = create(:knowledge_base)
        locale         = knowledge_base.kb_locales.first.system_locale.locale
        token          = Token.ensure_token!('KnowledgeBaseFeed', admin.id)

        get feed_knowledge_base_path(knowledge_base, locale, token: token), headers: lri_internal_headers

        expect(response).to have_http_status(:ok)
      end

      it 'does not block search engine robots that send a From header' do
        get '/api/v1/users/me', headers: { 'From' => 'googlebot(at)googlebot.com' }, as: :json

        expect(response.parsed_body['error']).not_to eq('zone_restricted')
      end
    end

    describe 'forged or incomplete internal zone' do
      def expect_unconfirmed
        expect(response).to have_http_status(:service_unavailable)
        expect(response.parsed_body['error']).to eq('zone_unconfirmed')
      end

      it 'answers X-LRI-Zone without the zone key with 503 and never runs the login', :aggregate_failures do
        sign_in(agent, { 'X-LRI-Zone' => 'internal' })

        expect_unconfirmed
        expect(session[:user_id]).to be_nil
      end

      it 'treats a wrong zone key as unconfirmed', :aggregate_failures do
        sign_in(agent, lri_internal_headers(key: 'x' * 40))

        expect_unconfirmed
      end

      it 'treats a missing Access JWT as unconfirmed', :aggregate_failures do
        sign_in(agent, lri_internal_headers(jwt: nil))

        expect_unconfirmed
      end

      it 'treats an Access JWT for another application as unconfirmed', :aggregate_failures do
        sign_in(agent, lri_internal_headers(jwt: lri_access_jwt(aud: 'outro-aplicativo')))

        expect_unconfirmed
      end

      it 'treats an expired Access JWT as unconfirmed', :aggregate_failures do
        sign_in(agent, lri_internal_headers(jwt: lri_access_jwt(exp: 5.minutes.ago)))

        expect_unconfirmed
      end

      it 'treats an Access JWT signed by another key as unconfirmed', :aggregate_failures do
        sign_in(agent, lri_internal_headers(jwt: lri_access_jwt(key: OpenSSL::PKey::RSA.generate(2048))))

        expect_unconfirmed
      end

      it 'treats a zone header with a different casing of the value as public', :aggregate_failures do
        sign_in(agent, lri_internal_headers.merge('X-LRI-Zone' => 'Internal'))

        expect_zone_denied
      end

      it 'keeps an internal agent session when the Access check fails later', :aggregate_failures do
        sign_in(agent, lri_internal_headers)
        expect(response).to have_http_status(:created)

        me(lri_internal_headers(jwt: lri_access_jwt(aud: 'outro-aplicativo')))
        expect_unconfirmed

        me(lri_internal_headers)
        expect(response).to have_http_status(:ok)
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

      it 'refuses the agent session replayed on the public zone and deletes it', :aggregate_failures do
        sign_in(agent, lri_internal_headers)
        old_record = current_session_record
        expect(old_record).to be_present

        me
        expect_zone_denied
        expect(ActiveRecord::SessionStore::Session.exists?(old_record.id)).to be(false)
      end

      it 'refuses the agent session on public GraphQL queries' do
        sign_in(agent, lri_internal_headers)
        post '/graphql', params: { query: '{ currentUser { id } }' }, as: :json

        expect_zone_denied
      end

      it 'refuses a customer session born in the internal zone when replayed on the public zone' do
        sign_in(customer, lri_internal_headers)
        me

        expect_zone_denied
      end

      it 'refuses a switched session ("entrar como") on the public zone', :aggregate_failures do
        sign_in(admin, lri_internal_headers)
        get "/api/v1/sessions/switch/#{customer.id}", headers: lri_internal_headers, as: :json
        expect(response).to have_http_status(:ok)

        me
        expect_zone_denied
      end
    end
  end
end
