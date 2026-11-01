# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'rails_helper'

RSpec.describe Lri::PrivateOrganizations do
  context 'with LRI_ORGANIZATIONS_PRIVATE=true' do
    before do
      allow(Lri::Zone::Config).to receive(:current).and_return(Lri::Zone::Config.new({ 'LRI_ORGANIZATIONS_PRIVATE' => 'true' }))
    end

    it 'creates organizations without sharing, even when sharing is requested' do
      expect(Organization.create!(name: 'Cliente Novo', shared: true)).to have_attributes(shared: false)
    end

    it 'lets an administrator turn sharing on afterwards' do
      organization = Organization.create!(name: 'Cliente Compartilhado')
      organization.update!(shared: true)

      expect(organization.reload.shared).to be(true)
    end
  end

  context 'without the setting (upstream behaviour)' do
    before { allow(Lri::Zone::Config).to receive(:current).and_return(Lri::Zone::Config.new({})) }

    it 'keeps the upstream default' do
      expect(Organization.create!(name: 'Cliente Padrão')).to have_attributes(shared: true)
    end
  end
end
