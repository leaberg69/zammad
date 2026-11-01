# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::Zone do
  subject(:zone) { described_class.resolve(config, ->(name) { headers[name] }) }

  let(:config) { Lri::Zone::Config.new(lri_zone_env) }

  before { enforce_lri_zone_guard }

  context 'without a zone header' do
    let(:headers) { {} }

    it { is_expected.to have_attributes(public?: true, reason: nil) }
  end

  context 'with all three internal proofs' do
    let(:headers) { lri_internal_headers }

    it { is_expected.to have_attributes(internal?: true, reason: nil) }
  end

  context 'with the zone header but no key' do
    let(:headers) { { 'X-LRI-Zone' => 'internal' } }

    it 'is public and says why' do
      expect(zone).to have_attributes(public?: true, reason: include('segredo de zona'))
    end
  end

  context 'with a JWT but no zone header' do
    let(:headers) { lri_internal_headers.except('X-LRI-Zone') }

    it { is_expected.to have_attributes(public?: true) }
  end

  context 'when the Access keys cannot be fetched' do
    let(:headers) { lri_internal_headers }

    before do
      allow(Lri::Zone::AccessVerifier).to receive(:jwks_fetcher).and_return(->(_url) { raise 'HTTP 503' })
      Lri::Zone::AccessVerifier.reset_cache!
    end

    it 'fails closed to the public zone and says why' do
      expect(zone).to have_attributes(public?: true, reason: include('JWT'))
    end
  end
end
