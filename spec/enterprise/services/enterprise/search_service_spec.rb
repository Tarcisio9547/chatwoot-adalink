require 'rails_helper'

# Adalink: #2083 - cobre so a montagem das condicoes de busca avancada
# (Enterprise::SearchService#build_where_conditions), sem depender de um
# cluster Elasticsearch/OpenSearch real (specs de integracao completos usam
# a tag :opensearch e exigem OPENSEARCH_URL, indisponivel neste ambiente).
RSpec.describe Enterprise::SearchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:whatsapp_inbox) { create(:channel_whatsapp, account: account).inbox }
  let(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let!(:mine_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: user) }
  let!(:colleague_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague) }

  let(:search_service) do
    SearchService.new(current_user: user, current_account: account, params: { q: 'zebraxpto' }, search_type: 'Message')
  end

  before do
    create(:inbox_member, user: user, inbox: whatsapp_inbox)
    create(:inbox_member, user: colleague, inbox: whatsapp_inbox)
  end

  describe '#build_where_conditions (private)' do
    context 'when the agent has the Setor role (conversation_participating_manage only)' do
      before { AccountUser.find_by(user: user, account: account).update(custom_role: setor_role) }

      it 'excludes the colleague conversation id from the search conditions' do
        conditions = search_service.send(:build_where_conditions)

        expect(conditions[:conversation_id]).to be_present
        expect(conditions[:conversation_id][:not]).to include(colleague_conversation.id)
        expect(conditions[:conversation_id][:not]).not_to include(mine_conversation.id)
      end
    end

    context 'when the user is an administrator' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:search_service) do
        SearchService.new(current_user: admin, current_account: account, params: { q: 'zebraxpto' }, search_type: 'Message')
      end

      it 'does not restrict by conversation_id' do
        conditions = search_service.send(:build_where_conditions)

        expect(conditions[:conversation_id]).to be_blank
      end
    end

    context 'when the agent has no custom role' do
      it 'does not restrict by conversation_id (current behaviour, unchanged)' do
        conditions = search_service.send(:build_where_conditions)

        expect(conditions[:conversation_id]).to be_blank
      end
    end

    context 'when the inbox is not Channel::Whatsapp' do
      let(:other_inbox) { create(:inbox, account: account) }
      let!(:other_colleague_conversation) { create(:conversation, account: account, inbox: other_inbox, assignee: colleague) }

      before do
        create(:inbox_member, user: user, inbox: other_inbox)
        create(:inbox_member, user: colleague, inbox: other_inbox)
        AccountUser.find_by(user: user, account: account).update(custom_role: setor_role)
      end

      it 'does not restrict the other inbox conversation (current behaviour, unchanged)' do
        conditions = search_service.send(:build_where_conditions)

        restricted_ids = conditions.dig(:conversation_id, :not) || []
        expect(restricted_ids).not_to include(other_colleague_conversation.id)
      end
    end
  end
end
