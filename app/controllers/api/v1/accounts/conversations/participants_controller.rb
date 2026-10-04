class Api::V1::Accounts::Conversations::ParticipantsController < Api::V1::Accounts::Conversations::BaseController
  # Adalink: ver a conversa (show?) não basta para mexer na lista. Quem só enxerga
  # (participante, visão restrita) se adicionaria numa conversa sem responsável e
  # ficaria com acesso mesmo depois de a roleta entregar o lead a outro corretor.
  # A regra está em ConversationPolicy#manage_participants?.
  before_action :authorize_manage_participants, only: [:create, :update]
  before_action :authorize_remove_participants, only: [:destroy]
  before_action :validate_user_ids, only: [:create, :update, :destroy]

  def show
    @participants = @conversation.conversation_participants
  end

  def create
    added_ids = participants_to_be_added_ids
    ActiveRecord::Base.transaction do
      @participants = added_ids.map { |user_id| @conversation.conversation_participants.find_or_create_by(user_id: user_id) }
    end
    dispatch_participants_changed(added_ids: added_ids, removed_ids: [])
  end

  def update
    added_ids = participants_to_be_added_ids
    removed_ids = participants_to_be_removed_ids
    # Quem só pode adicionar (responsável restrito) não pode mandar uma lista que tira alguém.
    authorize @conversation, :remove_participants? if removed_ids.any?
    ActiveRecord::Base.transaction do
      added_ids.each { |user_id| @conversation.conversation_participants.find_or_create_by(user_id: user_id) }
      removed_ids.each { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    dispatch_participants_changed(added_ids: added_ids, removed_ids: removed_ids)
    @participants = @conversation.conversation_participants
    render action: 'show'
  end

  def destroy
    removed_ids = requested_user_ids & current_participant_ids
    ActiveRecord::Base.transaction do
      removed_ids.each { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    dispatch_participants_changed(added_ids: [], removed_ids: removed_ids)
    head :ok
  end

  private

  # Avisa a tela ao vivo (ActionCable) de quem entrou e de quem saiu. Sem mudança real, não avisa.
  def dispatch_participants_changed(added_ids:, removed_ids:)
    return if added_ids.empty? && removed_ids.empty?

    Rails.configuration.dispatcher.dispatch(Events::Types::CONVERSATION_PARTICIPANTS_CHANGED, Time.zone.now,
                                            conversation: @conversation, added_user_ids: added_ids, removed_user_ids: removed_ids)
  end

  def authorize_manage_participants
    authorize @conversation, :manage_participants?
  end

  def authorize_remove_participants
    authorize @conversation, :remove_participants?
  end

  # user_ids tem que ser uma lista de inteiros (ou de números em texto). Qualquer outra
  # coisa (texto, objeto, lista misturada, ausente) é 422, nunca 500 e nunca "lista vazia".
  def validate_user_ids
    return if valid_user_ids_param?

    render_could_not_create_error('user_ids must be an array of integers')
  end

  def valid_user_ids_param?
    ids = params[:user_ids]
    ids.is_a?(Array) && ids.all? { |id| id.is_a?(Integer) || (id.is_a?(String) && id.match?(/\A\d+\z/)) }
  end

  # Só usuário confirmado entra como participante (a lista de candidatos da tela também é só de
  # confirmados). Quem já é participante e ainda não confirmou fica, e pode ser removido.
  def participants_to_be_added_ids
    confirmed_requested_user_ids - current_participant_ids
  end

  def participants_to_be_removed_ids
    current_participant_ids - requested_user_ids
  end

  # Adalink: qualquer agente da conta pode ser participante (a validação de acesso
  # à caixa saiu em 89e95cd07), então o servidor só aceita usuários DESTA conta.
  # Sem isso, um user_id de outra conta (ou inexistente) entraria direto na lista.
  def requested_user_ids
    @requested_user_ids ||= requested_account_users.pluck(:id)
  end

  def confirmed_requested_user_ids
    @confirmed_requested_user_ids ||= requested_account_users.where.not(confirmed_at: nil).pluck(:id)
  end

  def requested_account_users
    Current.account.users.where(id: params[:user_ids].map(&:to_i))
  end

  def current_participant_ids
    @current_participant_ids ||= @conversation.conversation_participants.pluck(:user_id)
  end
end
