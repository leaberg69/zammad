# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::ZoneGuard, 'configuration delivered to the interface' do
  describe '.frontend_value' do
    let(:enforced) { Lri::Zone::Config.new(lri_zone_env) }
    let(:off)      { Lri::Zone::Config.new({}) }

    it 'hides a third-party provider on the public zone' do
      expect(described_class.frontend_value('public', 'auth_google_oauth2', true, config: enforced)).to be(false)
    end

    it 'hides it when the zone is unknown, as long as the guard is on' do
      expect(described_class.frontend_value(nil, 'auth_microsoft_office365', true, config: enforced)).to be(false)
    end

    it 'keeps it on the internal zone' do
      expect(described_class.frontend_value('internal', 'auth_google_oauth2', true, config: enforced)).to be(true)
    end

    it 'keeps it with the guard off' do
      expect(described_class.frontend_value(nil, 'auth_google_oauth2', true, config: off)).to be(true)
    end

    it 'leaves other settings alone on the public zone' do
      expect(described_class.frontend_value('public', 'product_name', 'Central', config: enforced)).to eq('Central')
    end
  end

  describe 'configUpdates subscription', type: :graphql do
    let(:subscription) { 'subscription configUpdates { configUpdates { setting { key value } } }' }
    let(:mock_channel) { build_mock_channel }

    before { enforce_lri_zone_guard }

    def broadcast_for(zone_name)
      connection = Struct.new(:lri_zone).new(zone_name)
      mock_channel.define_singleton_method(:connection) { connection }
      gql.execute(subscription, context: { channel: mock_channel })
      Setting.set('auth_google_oauth2', true)
      mock_channel.mock_broadcasted_messages.last.dig(:result, 'data', 'configUpdates', 'setting')
    end

    it 'sends the provider as disabled to a public connection' do
      expect(broadcast_for('public')).to eq('key' => 'auth_google_oauth2', 'value' => false)
    end

    it 'sends the real value to an internal connection' do
      expect(broadcast_for('internal')).to eq('key' => 'auth_google_oauth2', 'value' => true)
    end
  end
end
