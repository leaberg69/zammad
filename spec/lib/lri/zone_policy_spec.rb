# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::ZonePolicy do
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
