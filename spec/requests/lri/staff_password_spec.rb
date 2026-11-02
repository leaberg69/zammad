# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Senha da equipe com a guarda ligada (docs/lri/PLANO.md, seção 2.9.3, controle 2): a equipe entra só por Google ou
#   Microsoft; senha e redefinição de senha da equipe recebem a mesma resposta de usuário desconhecido.
RSpec.describe 'Grupo LRI staff password policy', type: :request do
  let(:password) { 'Senha-Forte-123' }
  let(:agent)    { create(:agent, password: password) }
  let(:customer) { create(:customer, password: password) }

  def sign_in(login, given_password = password, headers = {}, **extra)
    post '/api/v1/signin', params: { username: login, password: given_password, fingerprint: '123456789', **extra }, headers: headers, as: :json
  end

  def unknown_user_response
    sign_in('ninguem@example.com', 'qualquer')
    [response.status, response.parsed_body]
  end

  before { enforce_lri_zone_guard }

  describe 'password login' do
    it 'answers an agent with the right password exactly like an unknown user, on the public zone', :aggregate_failures do
      expected = unknown_user_response

      sign_in(agent.login)

      expect([response.status, response.parsed_body]).to eq(expected)
      expect(session[:user_id]).to be_nil
    end

    it 'refuses the agent password on the internal zone too' do
      sign_in(agent.login, password, lri_internal_headers)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'does not count wrong agent passwords towards the account lockout' do
      expect { 3.times { sign_in(agent.login, 'errada') } }.not_to(change { agent.reload.login_failed })
    end

    it 'refuses the agent password on the GraphQL login as well' do
      post '/graphql', params: {
        query:     'mutation login($input: LoginInput!) { login(input: $input) { session { id } errors { message } } }',
        variables: { input: { login: agent.login, password: password } },
      }, headers: lri_internal_headers.merge('X-Browser-Fingerprint' => '123456789'), as: :json

      expect(response.parsed_body.dig('data', 'login', 'session')).to be_nil
    end

    it 'keeps password login for customers' do
      sign_in(customer.login)

      expect(response).to have_http_status(:created)
    end
  end

  describe 'password reset' do
    it 'issues no token and sends no email for an agent, with the same answer as for a customer', :aggregate_failures do
      post '/api/v1/users/password_reset', params: { username: customer.login }, as: :json
      customer_answer = [response.status, response.parsed_body]

      expect do
        post '/api/v1/users/password_reset', params: { username: agent.login }, as: :json
      end.not_to change(Token.where(action: 'PasswordReset', user_id: agent.id), :count)

      expect([response.status, response.parsed_body]).to eq(customer_answer)
    end

    it 'still issues a token for a customer' do
      expect do
        post '/api/v1/users/password_reset', params: { username: customer.login }, as: :json
      end.to change(Token.where(action: 'PasswordReset', user_id: customer.id), :count).by(1)
    end
  end

  describe 'emergency account' do
    let(:admin) { create(:admin, password: password) }

    before { enforce_lri_zone_guard('LRI_EMERGENCY_LOGIN' => admin.login.upcase) }

    it 'cannot use basic authentication on the internal zone without a second factor' do
      get '/ical/tickets', headers: lri_internal_headers.merge('Authorization' => ActionController::HttpAuthentication::Basic.encode_credentials(admin.login, password))

      expect(response).to have_http_status(:unauthorized)
    end

    it 'is refused on the public zone' do
      create(:user_two_factor_preference, :authenticator_app, user: admin)
      sign_in(admin.login)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'is refused on the internal zone without a configured second factor' do
      sign_in(admin.login, password, lri_internal_headers)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'asks for the second factor on the internal zone when it is configured', :aggregate_failures do
      two_factor = create(:user_two_factor_preference, :authenticator_app, user: admin)
      Setting.set('two_factor_authentication_method_authenticator_app', true)

      sign_in(admin.login, password, lri_internal_headers)
      expect(response).to have_http_status(:unprocessable_content)

      sign_in(admin.login, password, lri_internal_headers,
              two_factor_method: 'authenticator_app', two_factor_payload: two_factor.configuration[:code])
      expect(response).to have_http_status(:created)
    end
  end

  context 'when the guard is off' do
    before { allow(Lri::Zone::Config).to receive(:current).and_return(Lri::Zone::Config.new({})) }

    it 'keeps the upstream password login for agents' do
      sign_in(agent.login)

      expect(response).to have_http_status(:created)
    end
  end
end
