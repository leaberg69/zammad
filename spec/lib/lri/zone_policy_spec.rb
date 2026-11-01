# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::ZonePolicy do
  describe '.session_denial with a knowledge base preview token in the session' do
    let(:public_zone) { Lri::Zone.new(Lri::Zone::PUBLIC) }

    it 'refuses a staff token on the public zone' do
      token = create(:token, action: 'KnowledgeBasePreview', user: create(:agent))

      expect(described_class.session_denial({ 'kb_preview_token' => token.token }, public_zone)).to include('prévia')
    end

    it 'ignores an unknown token' do
      expect(described_class.session_denial({ 'kb_preview_token' => 'nao-existe' }, public_zone)).to be_nil
    end
  end

  describe '.staff?' do
    it 'is false for a customer' do
      expect(described_class.staff?(create(:customer))).to be(false)
    end

    it 'is true for an agent and an admin' do
      expect([create(:agent), create(:admin)].map { |user| described_class.staff?(user) }).to all(be(true))
    end

    it 'is true for a customer that also holds any non-customer permission' do
      role = create(:role, permission_names: %w[ticket.customer report])
      user = create(:customer, roles: [role])

      expect(described_class.staff?(user)).to be(true)
    end
  end
end
