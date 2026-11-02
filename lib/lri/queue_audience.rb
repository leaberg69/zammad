# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Regra das filas por público no servidor, independente da ordem dos Core Workflows: cliente de fora só nas filas
#   das marcas, colaborador só nas Interno::*. Só vale para chamado criado ou movido por tela ou API (screen definido).
module Lri::QueueAudience
  extend ActiveSupport::Concern

  included do
    before_create :lri_check_queue_audience
    before_update :lri_check_queue_audience, if: :group_id_changed?
  end

  def self.allowed?(user, group)
    return true if group.nil? || !user.permissions?('ticket.customer') || user.permissions?('ticket.agent')

    internal_names = Lri::Provisioning.internal_group_names
    return true if Group.where(name: internal_names).none?

    internal_queue = internal_names.include?(group.name)
    collaborator   = Lri::Provisioning::ORGANIZATIONS.pluck(:name).include?(user.organization&.name)
    internal_queue == collaborator
  end

  private

  def lri_check_queue_audience
    return if !screen || !UserInfo.current_user_id

    user = User.find_by(id: UserInfo.current_user_id)
    return if user.nil? || Lri::QueueAudience.allowed?(user, group)

    Rails.logger.warn "Lri::QueueAudience: usuário #{user.id} recusado no grupo #{group_id} (fila de outro público)"
    raise Exceptions::ApplicationModel.new(self, "Invalid value '#{group_id}' for field 'group_id'!")
  end
end
