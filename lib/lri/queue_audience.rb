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

  # Um filtro só, no fim: filtrar antes dos workflows esvaziaria um set_fixed_to sem dizer por quê.
  # Filtro no resultado final, depois de qualquer workflow (add_option, select, cadeia interrompida): opções,
  #   seleção e preenchimento do campo de fila só com filas do público do cliente.
  module ResultFilter
    def run
      super.tap { lri_filter_group_options }
    end

    private

    def lri_filter_group_options
      return if payload['class_name'] != 'Ticket' || user.nil? || Lri::QueueAudience.exempt?(user)

      dropped = %i[restrict_values select fill_in].map { |group| lri_drop_forbidden(group) }
      emptied = dropped.first && lri_restore_options_if_empty
      return if !emptied && dropped.drop(1).none?

      # A regra de público prevalece sobre os workflows: o campo volta a aparecer e a ser editável, senão o cliente
      #   fica sem como escolher uma fila permitida.
      Rails.logger.warn "Lri::QueueAudience: workflow deixaria o usuário #{user.id} sem fila do seu público; campo de fila liberado"
      @result[:visibility]['group_id'] = 'show'
      @result[:readonly]['group_id']   = false
    end

    # Só depois de o filtro de público ter retirado opções: se nenhuma sobrou, volta às filas do público do cliente.
    #   Uma restrição vazia feita de propósito por um workflow continua valendo. true se precisou.
    def lri_restore_options_if_empty
      return false if !@result[:restrict_values].key?('group_id')
      return false if Array(@result[:restrict_values]['group_id']).any?(&:present?)

      base = Group.where(id: Setting.get('customer_ticket_create_group_ids'), active: true).pluck(:id)
      @result[:restrict_values]['group_id'] = [''] + Lri::QueueAudience.allowed_group_ids(user, base).map(&:to_s)
      true
    end

    # true se algo foi retirado.
    def lri_drop_forbidden(group)
      value = @result.dig(group, 'group_id')
      return false if value.blank?

      allowed = Lri::QueueAudience.allowed_group_ids(user, value).map(&:to_s)
      kept    = Array(value).select { |entry| entry.blank? || allowed.include?(entry.to_s) }
      return false if kept.size == Array(value).size

      if value.is_a?(Array)
        @result[group]['group_id'] = kept
      else
        @result[group].delete('group_id')
      end
      true
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
