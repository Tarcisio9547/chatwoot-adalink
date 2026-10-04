require 'rails_helper'

# participant_ids só pode chegar aos AGENTES. O listener manda o payload com o campo e o job
# o tira dos tokens que não são de usuário (contato/widget). Vale para o payload recebido e
# para os eventos de conversa que o job remonta (CONVERSATION_UPDATE_EVENTS), na caixa
# WhatsApp (que refiltra por papel) e nas demais.
describe ActionCableBroadcastJob, '#perform' do
  let!(:account) { create(:account) }
  let!(:agent) { create(:user, account: account, role: :agent) }
  let!(:participant) { create(:user, account: account, role: :agent) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
  let(:contact_token) { conversation.contact_inbox.pubsub_token }
  let(:agent_payload) { conversation.agent_push_event_data.merge(account_id: account.id) }
  let(:broadcasts) { [] }

  before do
    create(:inbox_member, inbox: inbox, user: agent)
    create(:conversation_participant, conversation: conversation, account: account, user: participant)
    allow(ActionCable.server).to receive(:broadcast) { |token, message| broadcasts << { token: token, message: message } }
  end

  def data_for(token)
    broadcasts.find { |entry| entry[:token] == token }[:message][:data]
  end

  it 'gives participant_ids to the agents and takes it off the contact copy (payload sent as is)' do
    described_class.perform_now([agent.pubsub_token, contact_token], 'conversation.created', agent_payload)

    expect(data_for(agent.pubsub_token)[:participant_ids]).to contain_exactly(participant.id)
    expect(data_for(contact_token)).not_to have_key(:participant_ids)
    expect(data_for(contact_token)[:id]).to eq(conversation.display_id)
  end

  %w[conversation.updated conversation.status_changed conversation.read assignee.changed team.changed].each do |event_name|
    it "rebuilds #{event_name} with participant_ids for agents only" do
      described_class.perform_now([agent.pubsub_token, contact_token], event_name, agent_payload)

      expect(data_for(agent.pubsub_token)[:participant_ids]).to contain_exactly(participant.id)
      expect(data_for(contact_token)).not_to have_key(:participant_ids)
    end
  end

  it 'uses the participants as they are when the job runs, not when it was enqueued' do
    stale_payload = agent_payload
    ConversationParticipant.where(conversation: conversation).destroy_all

    described_class.perform_now([agent.pubsub_token], 'conversation.updated', stale_payload)

    expect(data_for(agent.pubsub_token)[:participant_ids]).to eq([])
  end

  it 'never adds participant_ids when the listener did not ask for it (old payloads, other events)' do
    plain = conversation.push_event_data.merge(account_id: account.id)

    described_class.perform_now([agent.pubsub_token, contact_token], 'conversation.updated', plain)

    expect(data_for(agent.pubsub_token)).not_to have_key(:participant_ids)
    expect(data_for(contact_token)).not_to have_key(:participant_ids)
  end

  it 'costs the same number of queries whatever the number of recipients' do
    count = lambda do |tokens|
      queries = 0
      counter = ->(_name, _started, _finished, _id, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA CACHE]) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        described_class.perform_now(tokens, 'conversation.created', agent_payload)
      end
      queries
    end
    count.call([agent.pubsub_token])
    one = count.call([agent.pubsub_token])
    many = count.call([agent.pubsub_token, participant.pubsub_token, contact_token])

    expect(many).to eq(one)
  end

  context 'with a WhatsApp conversation (role visibility on the job)' do
    let!(:whatsapp_inbox) do
      create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
    end
    let!(:whatsapp_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: agent) }
    let(:whatsapp_contact_token) { whatsapp_conversation.contact_inbox.pubsub_token }
    let(:whatsapp_payload) { whatsapp_conversation.agent_push_event_data.merge(account_id: account.id) }

    before do
      create(:inbox_member, inbox: whatsapp_inbox, user: agent)
      create(:conversation_participant, conversation: whatsapp_conversation, account: account, user: participant)
    end

    it 'gives participant_ids to the visible agents and not to the contact' do
      described_class.perform_now([agent.pubsub_token, participant.pubsub_token, whatsapp_contact_token], 'conversation.updated',
                                  whatsapp_payload)

      expect(data_for(agent.pubsub_token)[:participant_ids]).to contain_exactly(participant.id)
      expect(data_for(participant.pubsub_token)[:participant_ids]).to contain_exactly(participant.id)
      expect(data_for(whatsapp_contact_token)).not_to have_key(:participant_ids)
    end

    it 'sends an agent who lost the access the assignee.changed without messages but with the fresh participant_ids' do
      lost = create(:user, account: account, role: :agent)
      role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
      AccountUser.find_by(user: lost, account: account).update!(role: :agent, custom_role: role)
      create(:message, message_type: 'incoming', account: account, inbox: whatsapp_inbox, conversation: whatsapp_conversation, content: 'segredo')

      described_class.perform_now([lost.pubsub_token], 'assignee.changed', whatsapp_payload)

      expect(data_for(lost.pubsub_token)[:messages]).to be_blank
      expect(data_for(lost.pubsub_token)[:participant_ids]).to contain_exactly(participant.id)
      expect(data_for(lost.pubsub_token).to_json).not_to include('segredo')
    end
  end
end
