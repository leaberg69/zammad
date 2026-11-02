# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Regra das filas por público no servidor, independente da ordem dos Core Workflows: cliente de fora só nas filas
#   das marcas, colaborador só nas Interno::*. Só vale para chamado criado ou movido por tela ou API (screen definido).
module Lri::QueueAudience
  extend ActiveSupport::Concern

  INTERNAL_ROOT = 'Interno'.freeze
  # Texto do fork, em pt-BR, fora do catálogo de traduções do Zammad.
  MESSAGE = 'Esta fila não está disponível para a sua conta. Escolha outra fila.'.freeze # rubocop:disable Zammad/DetectTranslatableString

  # Antes da validação genérica do Core Workflow, para o cliente receber o motivo e não só "Invalid value".
  included do
    before_create :lri_check_queue_audience, prepend: true
    before_update :lri_check_queue_audience, prepend: true, if: :group_id_changed?
  end

  # A fila raiz e todas as descendentes, inclusive as criadas depois do provisionamento.
  def self.internal_groups
    Group.where(name: INTERNAL_ROOT).or(Group.where('name LIKE ?', "#{INTERNAL_ROOT}::%"))
  end

  def self.internal_group?(group)
    group.name == INTERNAL_ROOT || group.name.start_with?("#{INTERNAL_ROOT}::")
  end

  # Renomear ou apagar a raiz faria as filas internas parecerem externas: aí ninguém de fora cria chamado até corrigir.
  def self.internal_root_missing?
    Group.exists?(name: Lri::Provisioning::GROUPS.keys - [INTERNAL_ROOT]) && !Group.exists?(name: INTERNAL_ROOT)
  end

  def self.collaborator?(user)
    Lri::Provisioning::ORGANIZATIONS.pluck(:name).include?(user.organization&.name)
  end

  def self.exempt?(user)
    !user.permissions?('ticket.customer') || user.permissions?('ticket.agent')
  end

  # nil = permitido; senão, o motivo da recusa.
  def self.denial(user, group)
    return if group.nil? || exempt?(user)
    return 'grupo Interno ausente numa instalação provisionada' if internal_root_missing?

    internal     = internal_group?(group)
    collaborator = collaborator?(user)
    return if internal == collaborator

    internal ? 'fila interna para cliente de fora' : 'fila de marca para colaborador'
  end

  # Os ids permitidos dentre group_ids, com um número fixo de consultas, qualquer que seja o número de filas.
  def self.allowed_group_ids(user, group_ids)
    ids = Array(group_ids).compact_blank.map(&:to_i)
    return ids if exempt?(user)
    return [] if internal_root_missing?

    internal_ids = internal_groups.where(id: ids).pluck(:id)
    collaborator?(user) ? internal_ids : ids - internal_ids
  end

  # Lista base de filas do cliente (CoreWorkflow::Attributes::Group), antes de qualquer Core Workflow: o cliente
  #   só recebe filas do seu público. Workflow de administrador que acrescente, selecione ou fixe fila do outro
  #   público não é suportado; nesse caso o servidor recusa o chamado com MESSAGE (docs/lri/PLANO.md, seção 2.3).
  module GroupOptions
    def groups_customer
      groups = super
      groups.where(id: Lri::QueueAudience.allowed_group_ids(@attributes.user, groups.pluck(:id)))
    end
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
