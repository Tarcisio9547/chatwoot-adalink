require 'rails_helper'

# Na troca de responsável A->B, quem perde a conversa (A) pode receber dois
# eventos: assignee.changed (de propósito, pra tela tirar a conversa da lista) e
# conversation.updated (se A ainda estava na lista de destinatários calculada no
# disparo, antes da limpeza de participantes).
#
# Integração real (Conversation#update!, sem mockar listeners). Trava a ordem
# observada: conversation.updated sai ANTES de assignee.changed (o Rails roda os
# callbacks de commit na ordem inversa de registro). E confere que o
# conversation.updated enfileirado pra A não traz mensagem posterior à troca; o
# vazamento na execução do job é coberto por
# spec/jobs/action_cable_broadcast_job_role_visibility_spec.rb.
# rubocop:disable RSpec/DescribeClass -- teste de integracao do ciclo
# Conversation#update! -> callbacks -> SyncDispatcher -> ActionCableListener,
# nao de uma classe so.
describe 'assignee change event ordering' do
  let!(:account) { create(:account) }
  let!(:agent_a) { create(:user, account: account, role: :agent) }
  let!(:agent_b) { create(:user, account: account, role: :agent) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent_a) }

  before do
    create(:inbox_member, user: agent_a, inbox: whatsapp_inbox)
    create(:inbox_member, user: agent_b, inbox: whatsapp_inbox)
    conversation.inbox.reload
  end

  it 'dispatches conversation.updated before assignee.changed, and conversation.updated (if sent to A) carries no later message' do
    enqueued_events = []
    allow(ActionCableBroadcastJob).to receive(:perform_later) do |tokens, event_name, data|
      enqueued_events << { tokens: tokens, event_name: event_name, data: data }
    end

    conversation.update!(assignee: agent_b)

    event_names = enqueued_events.map { |e| e[:event_name] }
    assignee_changed_index = event_names.index('assignee.changed')
    conversation_updated_index = event_names.index('conversation.updated')

    expect(assignee_changed_index).not_to be_nil
    expect(conversation_updated_index).not_to be_nil
    # after_commit roda na ordem inversa de registro: conversation.updated
    # (after_update_commit, declarado por último) sai antes de assignee.changed
    # (AssignmentHandler, incluído antes).
    expect(conversation_updated_index).to be < assignee_changed_index

    conversation_updated_events_to_a = enqueued_events.select do |e|
      e[:event_name] == 'conversation.updated' && e[:tokens].include?(agent_a.pubsub_token)
    end

    conversation_updated_events_to_a.each do |e|
      messages = e[:data].is_a?(Hash) ? e[:data][:messages] : nil
      next if messages.blank?

      last_message_created_at = messages.filter_map { |m| m[:created_at] || m['created_at'] }.max
      expect(last_message_created_at.to_i).to be <= conversation.updated_at.to_i if last_message_created_at
    end
  end

  it 'does not leave A as a participant after the synchronous assignee.changed dispatch completes' do
    conversation.update!(assignee: agent_b)

    expect(conversation.reload.conversation_participants.map(&:user_id)).not_to include(agent_a.id)
  end
end
# rubocop:enable RSpec/DescribeClass
