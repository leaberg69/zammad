# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

# Rota do monitor externo (contrib/lri/deploy/nginx, /lri-monitor/health_check): o Nginx entrega ao Rails um GET sem
# query, com o token de monitoramento no cabeçalho X-LRI-Monitor-Token, e LriMonitorTokenMiddleware o passa ao
# health check. Tem de valer sem sessão, só no caminho exato e nunca na zona pública.
RSpec.describe 'Grupo LRI monitor token header', type: :request do
  let(:token) { Setting.get('monitoring_token') }

  # JWT do Access como o de um service token: sem e-mail, com o nome do token.
  let(:service_token_jwt) do
    payload = { aud: [LriZoneHelper::LRI_AUDIENCE], iss: "https://#{LriZoneHelper::LRI_TEAM_DOMAIN}",
                exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i, common_name: 'monitor-central.access' }
    JWT.encode(payload, LriZoneHelper.rsa_key, 'RS256', { kid: 'teste' })
  end

  let(:internal) { lri_internal_headers(jwt: service_token_jwt) }

  before { enforce_lri_zone_guard }

  def monitor(path, token_value, headers = internal)
    get path, headers: headers.merge('X-LRI-Monitor-Token' => token_value), as: :json
  end

  it 'accepts the token from the header in the internal zone', :aggregate_failures do
    monitor('/api/v1/monitoring/health_check', token)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include('healthy')
  end

  it 'refuses a wrong token from the header' do
    monitor('/api/v1/monitoring/health_check', 'errado0123456789abcdef')
    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses an empty token' do
    monitor('/api/v1/monitoring/health_check', '')
    expect(response).to have_http_status(:forbidden)
  end

  it 'ignores the header on any other monitoring path' do
    monitor('/api/v1/monitoring/status', token)
    expect(response).to have_http_status(:forbidden)
  end

  it 'refuses the route in the public zone even with a valid token' do
    monitor('/api/v1/monitoring/health_check', token, {})
    expect(response).to have_http_status(:forbidden)
  end
end
