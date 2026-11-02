# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Só na criação: um administrador ainda pode ligar o compartilhamento depois, de propósito.
module Lri::PrivateOrganizations
  extend ActiveSupport::Concern

  included do
    before_create :lri_force_private
  end

  private

  def lri_force_private
    return if !Lri::Zone::Config.current.organizations_private?
    return if shared == false

    Rails.logger.info "Lri::PrivateOrganizations: organização #{name.inspect} criada com shared=false (pedido: #{shared.inspect})"
    self.shared = false
  end
end
