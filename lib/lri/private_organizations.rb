# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Cada cliente vê só os próprios chamados (docs/lri/PLANO.md, seção 2.3): com LRI_ORGANIZATIONS_PRIVATE=true, toda
# organização nasce com "Organização compartilhada" desligada, venha do painel, da API, de importação ou da atribuição
# por domínio. Um administrador ainda pode ligar depois, de propósito, numa organização já criada.
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
