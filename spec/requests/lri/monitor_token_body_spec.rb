# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Rota do monitor externo (contrib/lri/deploy/nginx, /lri-monitor/health_check): o Nginx entrega ao Rails um GET sem
# query, com o token de monitoramento no corpo, como formulário. O health check tem de aceitá-lo por aí, sem sessão.
RSpec.describe 'Grupo LRI monitor token in the request body', type: :request do
  let(:token) { Setting.get('monitoring_token') }

  # JWT do Access como o de um service token: sem e-mail, com o nome do token.
  let(:service_token_jwt) do
    payload = { aud: [LriZoneHelper::LRI_AUDIENCE], iss: "https://#{LriZoneHelper::LRI_TEAM_DOMAIN}",
                exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i, common_name: 'monitor-central.access' }
    JWT.encode(payload, LriZoneHelper.rsa_key, 'RS256', { kid: 'teste' })
  end

  before { enforce_lri_zone_guard }

  def health_check(body, headers = lri_internal_headers(jwt: service_token_jwt))
    get '/api/v1/monitoring/health_check',
        headers: headers.merge('CONTENT_TYPE' => 'application/x-www-form-urlencoded'),
        env:     { input: body }
  end

  it 'accepts the token from the form body in the internal zone', :aggregate_failures do
    health_check("token=#{token}")
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('healthy')
  end

  it 'refuses a wrong token from the form body' do
    health_check('token=errado0123456789abcdef')
    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses an empty token from the form body' do
    health_check('token=')
    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses the route in the public zone even with a valid token' do
    health_check("token=#{token}", {})
    expect(response).to have_http_status(:forbidden)
  end
end
