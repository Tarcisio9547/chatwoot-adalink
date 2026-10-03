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

      # O papel "Sem atendente" enxerga TODA conversa sem atendente, não só as suas.
      # Sem limitar pelo início do período, a lista de ids enviada ao Elasticsearch
      # incluiria o histórico inteiro da conta.
      it 'excludes an unassigned conversation outside the search time window' do
        old_unassigned_conversation = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil,
                                                            last_activity_at: 200.days.ago)

        conditions = search_service.send(:build_where_conditions)

        visible_condition = conditions[:_or].find { |c| c.key?(:conversation_id) }
        expect(visible_condition[:conversation_id]).not_to include(old_unassigned_conversation.id)
        expect(visible_condition[:conversation_id]).to include(unassigned_conversation.id)
      end
    end

    context 'when the agent has the "Sem atendente" role and the search has an until bound' do
      before { AccountUser.find_by(user: user, account: account).update(custom_role: sem_atendente_role) }

      let(:search_service) do
        SearchService.new(current_user: user, current_account: account,
                          params: { q: 'zebraxpto', until: 10.days.ago.to_i.to_s }, search_type: 'Message')
      end

      # A mensagem esta dentro do periodo, mas a conversa teve atividade depois
      # do limite final. Excluir a conversa por last_activity_at <= until
      # esconderia um resultado legitimo; so o limite inicial e seguro (uma
      # mensagem criada depois de `since` implica last_activity_at >= since).
      it 'keeps a conversation whose last activity is after the until bound' do
        unassigned_conversation.update!(last_activity_at: 1.day.ago)

        conditions = search_service.send(:build_where_conditions)

        visible_condition = conditions[:_or].find { |c| c.key?(:conversation_id) }
        expect(visible_condition[:conversation_id]).to include(unassigned_conversation.id)
      end
    end

    context 'when the visible conversation list for the "Sem atendente" role is large' do
      before do
        AccountUser.find_by(user: user, account: account).update(custom_role: sem_atendente_role)
        stub_const('Enterprise::SearchService::ROLE_VISIBILITY_CONVERSATION_LIMIT', 2)
        allow(Rails.logger).to receive(:warn)
      end

      it 'keeps only the most recent conversations by last_activity_at and logs the cut' do
        mine_conversation.update!(last_activity_at: 3.days.ago)
        unassigned_conversation.update!(last_activity_at: 1.day.ago)
        newest_unassigned = create(:conversation, account: account, inbox: whatsapp_inbox, assignee: nil, last_activity_at: 1.hour.ago)

        conditions = search_service.send(:build_where_conditions)

        visible_condition = conditions[:_or].find { |c| c.key?(:conversation_id) }
        expect(visible_condition[:conversation_id]).to contain_exactly(newest_unassigned.id, unassigned_conversation.id)
        expect(Rails.logger).to have_received(:warn).with(/role visibility.*limit/i)
      end

      it 'asks the database for at most the cap plus one row (the LIMIT is in the SQL, not applied after loading)' do
        stub_const('Enterprise::SearchService::ROLE_VISIBILITY_CONVERSATION_LIMIT', 2)
        statements = []
        collector = ->(_name, _start, _finish, _id, payload) { statements << payload }

        ActiveSupport::Notifications.subscribed(collector, 'sql.active_record') { search_service.send(:build_where_conditions) }

        limited = statements.select { |payload| payload[:sql].include?('FROM "conversations"') && payload[:sql].include?('LIMIT') }
        expect(limited).not_to be_empty
        expect(limited.any? { |payload| payload[:sql].include?('LIMIT 3') || payload[:type_casted_binds].to_a.include?(3) }).to be true
      end

      it 'does not log when the list fits in the limit' do
        stub_const('Enterprise::SearchService::ROLE_VISIBILITY_CONVERSATION_LIMIT', 10)

        search_service.send(:build_where_conditions)

        expect(Rails.logger).not_to have_received(:warn).with(/role visibility/i)
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
