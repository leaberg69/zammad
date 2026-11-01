# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::Zone::AccessVerifier do
  subject(:verifier) { described_class.for(team_domain: LriZoneHelper::LRI_TEAM_DOMAIN, audiences: [LriZoneHelper::LRI_AUDIENCE]) }

  let(:key)       { LriZoneHelper.rsa_key }
  let(:jwk_hash)  { JWT::JWK.new(key, kid: 'teste').export.stringify_keys }
  let(:fetches)   { [] }
  let(:responses) { [{ 'keys' => [jwk_hash] }] }

  before do
    allow(described_class).to receive(:jwks_fetcher).and_return(lambda { |url|
      fetches << url
      result = responses.length > 1 ? responses.shift : responses.first
      raise result if result.is_a?(Exception)

      result
    })
    described_class.reset_cache!
  end

  def token(overrides: {}, header: { kid: 'teste' }, signing_key: key, algorithm: 'RS256')
    payload = { aud: [LriZoneHelper::LRI_AUDIENCE], iss: "https://#{LriZoneHelper::LRI_TEAM_DOMAIN}",
                exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i }.merge(overrides)
    JWT.encode(payload, signing_key, algorithm, header)
  end

  it 'accepts a valid token and fetches the keys from the team certs URL', :aggregate_failures do
    expect(verifier.failure_reason(token)).to be_nil
    expect(fetches).to eq(["https://#{LriZoneHelper::LRI_TEAM_DOMAIN}/cdn-cgi/access/certs"])
  end

  it 'refuses another issuer' do
    expect(verifier.failure_reason(token(overrides: { iss: 'https://outra.cloudflareaccess.com' }))).to include('Issuer')
  end

  it 'refuses an unsigned token (alg none)' do
    expect(verifier.failure_reason(JWT.encode({ aud: [LriZoneHelper::LRI_AUDIENCE] }, nil, 'none'))).to be_present
  end

  it 'refuses HS256 signed with the public key (algorithm confusion)' do
    forged = JWT.encode({ aud: [LriZoneHelper::LRI_AUDIENCE], iss: "https://#{LriZoneHelper::LRI_TEAM_DOMAIN}", exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i },
                        key.public_key.to_pem, 'HS256', { kid: 'teste' })

    expect(verifier.failure_reason(forged)).to be_present
  end

  it 'refuses a token without kid' do
    expect(verifier.failure_reason(token(header: {}))).to be_present
  end

  it 'refuses a token without exp' do
    expect(verifier.failure_reason(JWT.encode({ aud: [LriZoneHelper::LRI_AUDIENCE], iss: "https://#{LriZoneHelper::LRI_TEAM_DOMAIN}", iat: Time.zone.now.to_i }, key, 'RS256', { kid: 'teste' }))).to be_present
  end

  it 'tolerates a small clock skew' do
    expect(verifier.failure_reason(token(overrides: { exp: 10.seconds.ago.to_i }))).to be_nil
  end

  it 'caches the keys for an hour', :aggregate_failures do
    verifier.failure_reason(token)
    verifier.failure_reason(token)
    expect(fetches.size).to eq(1)

    travel 61.minutes
    verifier.failure_reason(token(overrides: { exp: 2.hours.from_now.to_i, iat: Time.zone.now.to_i }))
    expect(fetches.size).to eq(2)
  end

  context 'when the keys rotate' do
    let(:new_key)   { OpenSSL::PKey::RSA.generate(2048) }
    let(:responses) { [{ 'keys' => [jwk_hash] }, { 'keys' => [JWT::JWK.new(new_key, kid: 'nova').export.stringify_keys] }] }

    it 'refetches on an unknown kid, at most every five minutes', :aggregate_failures do
      verifier.failure_reason(token)
      travel 6.minutes
      expect(verifier.failure_reason(token(header: { kid: 'nova' }, signing_key: new_key))).to be_nil
      expect(fetches.size).to eq(2)

      verifier.failure_reason(token(header: { kid: 'desconhecida' }, signing_key: new_key))
      expect(fetches.size).to eq(2)
    end
  end

  context 'when fetching the keys fails after the cache expired' do
    let(:responses) { [{ 'keys' => [jwk_hash] }, RuntimeError.new('HTTP 503')] }

    it 'keeps using the previous keys and does not retry on every request', :aggregate_failures do
      verifier.failure_reason(token)
      travel 2.hours

      expect(verifier.failure_reason(token(overrides: { exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i }))).to be_nil
      expect(verifier.failure_reason(token(overrides: { exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i }))).to be_nil
      expect(fetches.size).to eq(2)
    end

    it 'stops accepting after the previous keys are older than a day' do
      verifier.failure_reason(token)
      travel 25.hours

      expect(verifier.failure_reason(token(overrides: { exp: 1.hour.from_now.to_i, iat: Time.zone.now.to_i }))).to include('indisponíveis')
    end
  end

  context 'when there were never any keys' do
    let(:responses) { [RuntimeError.new('DNS')] }

    it 'fails closed with a reason' do
      expect(verifier.failure_reason(token)).to include('indisponíveis')
    end
  end
end
