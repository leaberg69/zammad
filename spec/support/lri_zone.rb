# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Apoio aos testes da guarda de zona do Grupo LRI: configuração ligada e JWT do Cloudflare Access assinado por uma
# chave de teste, com o endpoint de chaves públicas trocado por essa chave.
module LriZoneHelper
  LRI_ZONE_KEY     = 'k' * 40
  LRI_TEAM_DOMAIN  = 'lriteste.cloudflareaccess.com'.freeze
  LRI_AUDIENCE     = 'aud-teste-central'.freeze
  LRI_INTERNAL_URL = 'https://atendimento.example.com'.freeze

  def self.rsa_key
    @rsa_key ||= OpenSSL::PKey::RSA.generate(2048)
  end

  def lri_zone_env(overrides = {})
    {
      'LRI_ZONE_GUARD'         => 'enforce',
      'LRI_ZONE_KEY'           => LRI_ZONE_KEY,
      'LRI_ACCESS_TEAM_DOMAIN' => LRI_TEAM_DOMAIN,
      'LRI_ACCESS_AUD'         => LRI_AUDIENCE,
      'LRI_INTERNAL_URL'       => LRI_INTERNAL_URL,
    }.merge(overrides)
  end

  def enforce_lri_zone_guard(overrides = {})
    config = Lri::Zone::Config.new(lri_zone_env(overrides))
    allow(Lri::Zone::Config).to receive(:current).and_return(config)
    jwk = JWT::JWK.new(LriZoneHelper.rsa_key, kid: 'teste')
    allow(Lri::Zone::AccessVerifier).to receive(:jwks_fetcher).and_return(->(_url) { { 'keys' => [jwk.export.stringify_keys] } })
    Lri::Zone::AccessVerifier.reset_cache!
  end

  def lri_access_jwt(aud: LRI_AUDIENCE, iss: "https://#{LRI_TEAM_DOMAIN}", exp: 1.hour.from_now, key: LriZoneHelper.rsa_key)
    payload = { aud: [aud], iss: iss, exp: exp.to_i, iat: Time.zone.now.to_i, email: 'agente@lri.com.br' }
    JWT.encode(payload, key, 'RS256', { kid: 'teste' })
  end

  def lri_internal_headers(jwt: lri_access_jwt, key: LRI_ZONE_KEY)
    { 'X-LRI-Zone' => 'internal', 'X-LRI-Zone-Key' => key, 'Cf-Access-Jwt-Assertion' => jwt }.compact
  end
end

RSpec.configure do |config|
  config.include LriZoneHelper
end
