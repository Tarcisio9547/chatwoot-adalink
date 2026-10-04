require 'rails_helper'

# POST /conversations com a caixa em lock_to_single_conversation devolve a
# conversa que o contato já tem em vez de criar outra. Numa caixa WhatsApp, quem
# não enxerga essa conversa pelo papel (Setor) não pode recebê-la nem postar
# mensagem nela. Outras caixas e quem enxerga a conversa seguem como antes.
describe 'POST /conversations on an existing conversation (role visibility)', type: :request do
  let!(:account) { create(:account) }
  let!(:setor_agent) { create(:user, account: account, role: :agent) }
  let!(:owner) { create(:user, account: account, role: :agent) }
  let!(:admin) { create(:user, account: account, role: :administrator) }
  let!(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let!(:contact) { create(:contact, account: account) }
  let!(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: whatsapp_inbox, source_id: '5511999990000') }
  let!(:existing) do
    create(:conversation, account: account, inbox: whatsapp_inbox, contact: contact, contact_inbox: contact_inbox, assignee: owner)
  end

  before do
    whatsapp_inbox.update!(lock_to_single_conversation: true)
    [setor_agent, owner].each { |user| create(:inbox_member, user: user, inbox: whatsapp_inbox) }
    AccountUser.find_by(user: setor_agent, account: account).update!(custom_role: setor_role)
    AccountUser.find_by(user: owner, account: account).update!(custom_role: setor_role)
    allow(Rails.configuration.dispatcher).to receive(:dispatch)
  end

  def create_conversation(user, source_id: contact_inbox.source_id)
    post "/api/v1/accounts/#{account.id}/conversations",
         headers: user.create_new_auth_token,
         params: { source_id: source_id, message: { content: 'mensagem do intruso' } },
         as: :json
  end

  it 'answers 404, does not return the colleague conversation and does not post a message' do
    create_conversation(setor_agent)

    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(existing.display_id.to_s)
    expect(existing.messages.where(content: 'mensagem do intruso')).to be_empty
  end

  it 'returns the existing conversation and posts the message for the assignee' do
    create_conversation(owner)

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['id']).to eq(existing.display_id)
    expect(existing.messages.where(content: 'mensagem do intruso').count).to eq(1)
  end

  it 'returns the existing conversation for an administrator' do
    create_conversation(admin)

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['id']).to eq(existing.display_id)
  end

  it 'returns the existing conversation to a Setor agent who is an explicit participant' do
    create(:conversation_participant, conversation: existing, account: account, user: setor_agent)

    create_conversation(setor_agent)

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['id']).to eq(existing.display_id)
  end

  it 'still creates a new conversation when the contact has none yet' do
    existing.destroy!

    expect { create_conversation(setor_agent) }.to change(Conversation, :count).by(1)
    expect(response).to have_http_status(:success)
  end

  # A regra vale em TODOS os canais: com "uma conversa por contato", quem tem visão restrita e não enxerga
  # a conversa existente não a recebe nem posta mensagem nela (404, que não confirma que ela existe).
  describe 'on a channel that is not WhatsApp (web widget, e-mail, API...)' do
    let!(:other_inbox) { create(:inbox, account: account, lock_to_single_conversation: true) }
    let!(:other_contact_inbox) { create(:contact_inbox, contact: contact, inbox: other_inbox) }
    let!(:other) do
      create(:conversation, account: account, inbox: other_inbox, contact: contact, contact_inbox: other_contact_inbox, assignee: owner)
    end

    before do
      [setor_agent, owner].each { |user| create(:inbox_member, user: user, inbox: other_inbox) }
    end

    it 'answers 404, does not return the colleague conversation and does not post the message' do
      create_conversation(setor_agent, source_id: other_contact_inbox.source_id)

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(other.display_id.to_s)
      expect(other.messages.where(content: 'mensagem do intruso')).to be_empty
    end

    it 'returns it to the assignee and posts the message' do
      create_conversation(owner, source_id: other_contact_inbox.source_id)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(other.display_id)
      expect(other.messages.where(content: 'mensagem do intruso').count).to eq(1)
    end

    it 'returns it to a restricted agent who is an explicit participant' do
      create(:conversation_participant, conversation: other, account: account, user: setor_agent)

      create_conversation(setor_agent, source_id: other_contact_inbox.source_id)

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(other.display_id)
    end

    it 'keeps returning it to an administrator and to an agent without custom role (current behaviour, unchanged)' do
      plain = create(:user, account: account, role: :agent)
      create(:inbox_member, user: plain, inbox: other_inbox)

      create_conversation(admin, source_id: other_contact_inbox.source_id)
      expect(response).to have_http_status(:success)

      create_conversation(plain, source_id: other_contact_inbox.source_id)
      expect(response).to have_http_status(:success)
      expect(response.parsed_body['id']).to eq(other.display_id)
    end

    it 'still creates a new conversation when the contact has none yet' do
      other.destroy!

      expect { create_conversation(setor_agent, source_id: other_contact_inbox.source_id) }.to change(Conversation, :count).by(1)
      expect(response).to have_http_status(:success)
    end
  end
end
