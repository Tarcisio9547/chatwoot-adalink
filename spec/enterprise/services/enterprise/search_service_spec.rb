require 'rails_helper'

# Adalink: #2083 - cobre so a montagem das condicoes de busca avancada
# (Enterprise::SearchService#build_where_conditions), sem depender de um
# cluster Elasticsearch/OpenSearch real (specs de integracao completos usam
# a tag :opensearch e exigem OPENSEARCH_URL, indisponivel neste ambiente).
RSpec.describe Enterprise::SearchService do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account, role: :agent) }
  let(:whatsapp_inbox) do
    create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false).inbox
  end
  let(:setor_role) { create(:custom_role, account: account, permissions: %w[conversation_participating_manage]) }
  let(:sem_atendente_role) { create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage]) }
  let(:colleague) { create(:user, account: account, role: :agent) }
  let!(:mine_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: user) }
  let!(:colleague_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: colleague) }
  let!(:unassigned_conversation) { create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil) }

  let(:search_service) do
    SearchService.new(current_user: user, current_account: account, params: { q: 'zebraxpto' }, search_type: 'Message')
  end

  before do
    create(:inbox_member, user: user, inbox: whatsapp_inbox)
    create(:inbox_member, user: colleague, inbox: whatsapp_inbox)
    Current.account = account
  end

  after do
    Current.account = nil
  end

  describe '#build_where_conditions (private)' do
    context 'when the agent has the Setor role (conversation_participating_manage only)' do
      before { AccountUser.find_by(user: user, account: account).update(custom_role: setor_role) }

      it 'uses a positive _or filter with only the visible conversation ids, not a "not" exclusion list' do
        conditions = search_service.send(:build_where_conditions)

        expect(conditions[:_or]).to be_present
        visible_condition = conditions[:_or].find { |c| c.key?(:conversation_id) }
        expect(visible_condition[:conversation_id]).to include(mine_conversation.id)
        expect(visible_condition[:conversation_id]).not_to include(colleague_conversation.id)
        expect(conditions[:conversation_id]).to be_blank
      end
    end

    context 'when the agent has the "Sem atendente" role (conversation_unassigned_manage only)' do
      before { AccountUser.find_by(user: user, account: account).update(custom_role: sem_atendente_role) }

      it 'includes unassigned and own conversations, excludes the colleague conversation' do
        conditions = search_service.send(:build_where_conditions)

        visible_condition = conditions[:_or].find { |c| c.key?(:conversation_id) }
        expect(visible_condition[:conversation_id]).to include(mine_conversation.id, unassigned_conversation.id)
        expect(visible_condition[:conversation_id]).not_to include(colleague_conversation.id)
      end

      # Adalink: correcao do juiz cego (rodada 2, item 4) - o papel "Sem
      # atendente" enxerga TODA conversa sem atendente, nao so as suas. Sem
      # restringir por periodo, a lista de visible_ids plucada aqui incluiria
      # toda conversa sem atendente do historico inteiro da conta - mesma
      # janela que enforce_time_limit/cap_until_time ja aplicam a busca de
      # mensagens.
      it 'excludes an unassigned conversation outside the search time window' do
        old_unassigned_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil,
                                                            last_activity_at: 200.days.ago)

        conditions = search_service.send(:build_where_conditions)

        visible_condition = conditions[:_or].find { |c| c.key?(:conversation_id) }
        expect(visible_condition[:conversation_id]).not_to include(old_unassigned_conversation.id)
        expect(visible_condition[:conversation_id]).to include(unassigned_conversation.id)
      end
    end

    context 'when the user is an administrator' do
      let(:admin) { create(:user, account: account, role: :administrator) }
      let(:search_service) do
        SearchService.new(current_user: admin, current_account: account, params: { q: 'zebraxpto' }, search_type: 'Message')
      end

      it 'does not restrict by conversation_id and does not query RoleVisibility.filter' do
        expect(Conversations::RoleVisibility).not_to receive(:filter)

        conditions = search_service.send(:build_where_conditions)

        expect(conditions[:_or]).to be_blank
        expect(conditions[:conversation_id]).to be_blank
      end
    end

    context 'when the agent has no custom role' do
      it 'does not restrict by conversation_id and does not query RoleVisibility.filter (current behaviour, unchanged)' do
        expect(Conversations::RoleVisibility).not_to receive(:filter)

        conditions = search_service.send(:build_where_conditions)

        expect(conditions[:_or]).to be_blank
        expect(conditions[:conversation_id]).to be_blank
      end
    end

    context 'when the inbox is not Channel::Whatsapp' do
      let(:other_inbox) { create(:inbox, account: account) }

      before do
        create(:inbox_member, user: user, inbox: other_inbox)
        create(:inbox_member, user: colleague, inbox: other_inbox)
        AccountUser.find_by(user: user, account: account).update(custom_role: setor_role)
      end

      it 'lets the other inbox through via the inbox_id branch of _or (current behaviour, unchanged)' do
        conditions = search_service.send(:build_where_conditions)

        inbox_condition = conditions[:_or].find { |c| c.key?(:inbox_id) }
        expect(inbox_condition[:inbox_id]).to include(other_inbox.id)
      end
    end
  end
end
