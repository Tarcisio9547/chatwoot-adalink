require 'rails_helper'

# Adalink: correcao do juiz cego (rodada 2, item 2) - teste de integracao
# ponta a ponta pelo dispatcher de verdade (sync + async), nao chamando os
# listeners diretamente. Cobre reatribuicao A->B numa caixa Channel::Whatsapp:
# participantes (A sai, participante manual fica, B entra), destinatarios do
# evento ao vivo (ActionCableBroadcastJob), bloqueio de abertura direta via
# ConversationPolicy#show? para A, e a busca (SearchService). Tambem A->nil e
# A->B->A.
# rubocop:disable RSpec/DescribeClass -- teste de integracao ponta a ponta
# (dispatcher real + varios models/services), nao tem uma unica classe alvo.
describe 'WhatsApp reassignment visibility (integration)', :active_job do
  include ActiveJob::TestHelper

  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:manual_participant) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }

  before do
    create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
    create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
    create(:inbox_member, user: manual_participant, inbox: whatsapp_inbox)

    AccountUser.find_by(user: agent_a, account: account).update(custom_role: setor_role)
    AccountUser.find_by(user: agent_b, account: account).update(custom_role: setor_role)

    conversation.conversation_participants.create!(user: agent_a)
    conversation.conversation_participants.create!(user: manual_participant)

    # HACK: to reload conversation inbox members (mesmo padrao usado em
    # action_cable_listener_spec.rb original) - os membros sao adicionados
    # acima, depois da conversa (let!) ja ter carregado a associacao inbox.
    conversation.inbox.reload

    allow(ActionCableBroadcastJob).to receive(:perform_later)
  end

  after { Current.account = nil }

  # Adalink: o matcher `permit` (Pundit RSpec) so e ativado automaticamente
  # para specs com metadata type: :policy, inferido pelo path spec/policies/.
  # Fora desse path (aqui, em spec/integration/), chamamos a policy
  # diretamente, sem depender do matcher.
  def conversation_policy_allows?(user, conversation)
    context = { user: user, account: account, account_user: AccountUser.find_by(user: user, account: account) }
    ConversationPolicy.new(context, conversation).show?
  end

  def search_finds_conversation?(user)
    Current.account = account
    search_service = SearchService.new(current_user: user, current_account: account, params: { q: conversation.display_id.to_s },
                                       search_type: 'Conversation')
    search_service.perform[:conversations].include?(conversation)
  end

  context 'when the conversation is reassigned from A to B' do
    it 'removes A from participants, keeps the manual participant, and adds B' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_b) }

      participant_ids = conversation.reload.conversation_participants.map(&:user_id)
      expect(participant_ids).not_to include(agent_a.id)
      expect(participant_ids).to include(manual_participant.id)
      expect(participant_ids).to include(agent_b.id)
    end

    it 'sends the live assignee.changed event to A (loses it) and to B (gains it)' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_b) }

      expect(ActionCableBroadcastJob).to have_received(:perform_later).at_least(:once) do |tokens, event_name, _payload|
        next unless event_name == 'assignee.changed'

        expect(tokens).to include(agent_a.pubsub_token)
        expect(tokens).to include(agent_b.pubsub_token)
      end
    end

    it 'blocks A from opening the conversation directly (ConversationPolicy#show?)' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_b) }

      expect(conversation_policy_allows?(agent_a, conversation.reload)).to be false
    end

    it 'A can no longer find the conversation in search, B can' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_b) }

      expect(search_finds_conversation?(agent_a)).to be false
      expect(search_finds_conversation?(agent_b)).to be true
    end
  end

  # Trocar o time por um do qual o responsavel nao faz parte zera o responsavel
  # (AssignmentHandler#ensure_assignee_is_from_team). Os dois eventos
  # (assignee.changed e team.changed) saem do mesmo after_commit, lendo
  # saved_changes do mesmo objeto: nenhum listener sincrono pode apaga-los.
  context 'when a team change clears the assignee' do
    let!(:observer) { create(:user, account: account, role: :agent) }
    let!(:team) { create(:team, account: account) }

    before { create(:inbox_member, user: observer, inbox: whatsapp_inbox) }

    it 'keeps the saved changes of the conversation after update!' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(team: team) }

      expect(conversation.assignee_id).to be_nil
      expect(conversation.saved_change_to_assignee_id?).to be true
      expect(conversation.saved_change_to_team_id?).to be true
    end

    it 'still broadcasts team.changed' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(team: team) }

      expect(ActionCableBroadcastJob).to have_received(:perform_later).with(anything, 'team.changed', anything)
    end
  end

  context 'when the conversation is unassigned from A' do
    it 'removes A from participants (conversation becomes unassigned)' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: nil) }

      expect(conversation.reload.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
    end
  end

  context 'when the conversation is reassigned from A to B and back to A' do
    it 'keeps A as a participant after being reassigned back' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_b) }
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_a) }

      participant_ids = conversation.reload.conversation_participants.map(&:user_id)
      expect(participant_ids).to include(agent_a.id)
      expect(participant_ids).not_to include(agent_b.id)
    end

    it 'A can open and find the conversation again' do
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_b) }
      perform_enqueued_jobs(only: EventDispatcherJob) { conversation.update!(assignee: agent_a) }

      expect(conversation_policy_allows?(agent_a, conversation.reload)).to be true
      expect(search_finds_conversation?(agent_a)).to be true
    end
  end
end
# rubocop:enable RSpec/DescribeClass
