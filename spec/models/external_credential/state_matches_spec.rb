# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe ExternalCredential, '.state_matches?' do
  it 'matches an equal state' do
    expect(described_class.state_matches?('abc123', 'abc123')).to be(true)
  end

  it 'does not match a different state' do
    expect(described_class.state_matches?('abc123', 'xyz789')).to be(false)
  end

  it 'requires both values', :aggregate_failures do
    expect(described_class.state_matches?(nil, nil)).to be(false)
    expect(described_class.state_matches?(nil, 'abc123')).to be(false)
    expect(described_class.state_matches?('', '')).to be(false)
    expect(described_class.state_matches?('abc123', nil)).to be(false)
  end

  %w[google microsoft_graph microsoft365 exchange facebook].each do |provider|
    it "requires a matching state when linking a #{provider} account" do
      expect { described_class.link_account(provider, nil, { code: 'x' }) }
        .to raise_error(Exceptions::UnprocessableContent, 'Invalid OAuth state parameter.')
    end
  end
end
