class Api::V1::Accounts::Conversations::ParticipantsController < Api::V1::Accounts::Conversations::BaseController
  def show
    @participants = @conversation.conversation_participants
  end

  def create
    ActiveRecord::Base.transaction do
      @participants = participants_to_be_added_ids.map { |user_id| @conversation.conversation_participants.find_or_create_by(user_id: user_id) }
    end
  end

  def update
    ActiveRecord::Base.transaction do
      participants_to_be_added_ids.each { |user_id| @conversation.conversation_participants.find_or_create_by(user_id: user_id) }
      participants_to_be_removed_ids.each { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    @participants = @conversation.conversation_participants
    render action: 'show'
  end

  def destroy
    ActiveRecord::Base.transaction do
      params[:user_ids].map { |user_id| @conversation.conversation_participants.find_by(user_id: user_id)&.destroy }
    end
    head :ok
  end

  private

  def participants_to_be_added_ids
    requested_user_ids - current_participant_ids
  end

  def participants_to_be_removed_ids
    current_participant_ids - requested_user_ids
  end

  # Adalink: qualquer agente da conta pode ser participante (a validação de acesso
  # à caixa saiu em 89e95cd07), então o servidor só aceita usuários DESTA conta.
  # Sem isso, um user_id de outra conta (ou inexistente) entraria direto na lista.
  # `fetch` mantém o erro 422 quando a chamada vem sem user_ids: um PUT sem o campo
  # não pode virar "lista vazia" e apagar todos os participantes.
  def requested_user_ids
    @requested_user_ids ||= Current.account.users.where(id: Array(params.fetch(:user_ids))).pluck(:id)
  end

  def current_participant_ids
    @current_participant_ids ||= @conversation.conversation_participants.pluck(:user_id)
  end
end
