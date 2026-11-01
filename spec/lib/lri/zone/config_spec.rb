# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::Zone::Config do
  it 'is off unless explicitly enforced' do
    expect(described_class.new({})).to have_attributes(enforced?: false, problems: [])
  end

  it 'refuses to boot an enforced guard with incomplete settings' do
    config = described_class.new({ 'LRI_ZONE_GUARD' => 'enforce', 'LRI_ZONE_KEY' => 'curta' })

    expect { config.validate! }.to raise_error(ArgumentError, %r{LRI_ZONE_KEY.*LRI_ACCESS_TEAM_DOMAIN.*LRI_ACCESS_AUD.*LRI_INTERNAL_URL})
  end
end
