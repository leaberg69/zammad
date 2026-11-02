# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Regra das filas por público no servidor, independente da ordem dos Core Workflows: cliente de fora só nas filas
#   das marcas, colaborador só nas Interno::*. Só vale para chamado criado ou movido por tela ou API (screen definido).
module Lri::QueueAudience
  extend ActiveSupport::Concern

  INTERNAL_ROOT = 'Interno'.freeze
  # Texto do fork, em pt-BR, fora do catálogo de traduções do Zammad.
  MESSAGE = 'Esta fila não está disponível para a sua conta. Escolha outra fila.'.freeze # rubocop:disable Zammad/DetectTranslatableString

  included do
    before_create :lri_check_queue_audience
    before_update :lri_check_queue_audience, if: :group_id_changed?
  end

  # A fila raiz e todas as descendentes, inclusive as criadas depois do provisionamento.
  def self.internal_groups
    Group.where(name: INTERNAL_ROOT).or(Group.where('name LIKE ?', "#{INTERNAL_ROOT}::%"))
  end

  def self.internal_group?(group)
    group.name == INTERNAL_ROOT || group.name.start_with?("#{INTERNAL_ROOT}::")
  end

  def self.collaborator?(user)
    Lri::Provisioning::ORGANIZATIONS.pluck(:name).include?(user.organization&.name)
  end

  # nil = permitido; senão, o motivo da recusa.
  def self.denial(user, group)
    return if group.nil? || !user.permissions?('ticket.customer') || user.permissions?('ticket.agent')
    return if !Group.exists?(name: INTERNAL_ROOT)

    internal     = internal_group?(group)
    collaborator = collaborator?(user)
    return if internal == collaborator

    internal ? 'fila interna para cliente de fora' : 'fila de marca para colaborador'
  end

  private

  def lri_check_queue_audience
    return if !screen || !UserInfo.current_user_id

    user   = User.find_by(id: UserInfo.current_user_id)
    reason = user && Lri::QueueAudience.denial(user, group)
    return if !reason

    Rails.logger.warn "Lri::QueueAudience: recusado reason=queue_audience user=#{user.id} group=#{group_id} motivo=#{reason}"
    raise Exceptions::UnprocessableContent, MESSAGE
  end
end
