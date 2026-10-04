require 'rails_helper'

RSpec.describe ConversationPolicy, type: :policy do
  subject { described_class }

  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:agent_account_user) { agent.account_users.find_by(account: account) }
  let(:context) { { user: agent, account: account, account_user: agent_account_user } }

  before do
    create(:inbox_member, user: agent, inbox: inbox)
  end

  # Criar, alterar ou remover participantes: administrador, agente sem custom_role,
  # custom_role com conversation_manage ("Todas") ou o RESPONSÁVEL atual. Qualquer outro
  # (inclusive restrito se adicionando numa conversa sem responsável, ou participante
  # tentando adicionar outros) não pode: é o que impede alguém de se dar acesso eterno.
  permissions :manage_participants? do
    let(:other_agent) { create(:user, account: account, role: :agent) }
    let(:unassigned) { create(:conversation, account: account, inbox: inbox, assignee: nil) }
    let(:assigned_to_other) { create(:conversation, account: account, inbox: inbox, assignee: other_agent) }

    let(:restrict!) do
      lambda do |permissions|
        role = create(:custom_role, account: account, permissions: permissions)
        agent_account_user.update!(role: :agent, custom_role: role)
      end
    end

    it 'allows an administrator' do
      agent_account_user.update!(role: :administrator)

      expect(subject).to permit(context, assigned_to_other)
    end

    it 'allows an agent without custom role (default Chatwoot role)' do
      expect(subject).to permit(context, assigned_to_other)
      expect(subject).to permit(context, unassigned)
    end

    it 'allows a custom role with conversation_manage ("Todas")' do
      restrict!.call(%w[conversation_manage])

      expect(subject).to permit(context, assigned_to_other)
      expect(subject).to permit(context, unassigned)
    end

    %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
      context "with the restricted visibility #{permission}" do
        before { restrict!.call([permission]) }

        it 'allows the current assignee' do
          conversation = create(:conversation, account: account, inbox: inbox, assignee: agent)

          expect(subject).to permit(context, conversation)
        end

        it 'denies adding oneself to an unassigned conversation' do
          expect(subject).not_to permit(context, unassigned)
        end

        it 'denies adding oneself to a conversation assigned to someone else' do
          expect(subject).not_to permit(context, assigned_to_other)
        end

        it 'denies a participant (who sees the conversation but is not the assignee)' do
          create(:conversation_participant, conversation: assigned_to_other, account: account, user: agent)

          expect(subject).not_to permit(context, assigned_to_other)
        end
      end
    end

    it 'denies a custom role with no conversation permission at all' do
      restrict!.call(%w[contact_manage])

      expect(subject).not_to permit(context, assigned_to_other)
    end

    it 'denies a user who is not in the account' do
      outsider = create(:user, account: create(:account), role: :agent)
      outsider_context = { user: outsider, account: account, account_user: nil }

      expect(subject).not_to permit(outsider_context, assigned_to_other)
    end

    it 'denies an agent bot even if the ids collide with the assignee' do
      bot = create(:agent_bot)
      conversation = create(:conversation, account: account, inbox: inbox, assignee: agent)
      bot_context = { user: bot, account: account, account_user: nil }

      expect(subject).not_to permit(bot_context, conversation)
    end
  end

  permissions :show? do
    context 'when role grants conversation_unassigned_manage' do
      let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_unassigned_manage']) }

      before do
        agent_account_user.update!(role: :agent, custom_role: custom_role)
      end

      it 'allows access to conversations assigned to the agent' do
        conversation = create(:conversation, account: account, inbox: inbox, assignee: agent)

        expect(subject).to permit(context, conversation)
      end

      it 'denies access to conversations assigned to someone else' do
        other_agent = create(:user, account: account, role: :agent)
        conversation = create(:conversation, account: account, inbox: inbox, assignee: other_agent)

        expect(subject).not_to permit(context, conversation)
      end

      it 'allows access to a conversation assigned to someone else where the agent is a participant' do
        other_agent = create(:user, account: account, role: :agent)
        conversation = create(:conversation, account: account, inbox: inbox, assignee: other_agent)
        create(:conversation_participant, conversation: conversation, account: account, user: agent)

        expect(subject).to permit(context, conversation)
      end

      it 'allows access to an unassigned conversation where the agent is a participant' do
        conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)
        create(:conversation_participant, conversation: conversation, account: account, user: agent)

        expect(subject).to permit(context, conversation)
      end

      it 'does not open the conversation of someone else to a participant of ANOTHER conversation' do
        other_agent = create(:user, account: account, role: :agent)
        conversation = create(:conversation, account: account, inbox: inbox, assignee: other_agent)
        another = create(:conversation, account: account, inbox: inbox, assignee: other_agent)
        create(:conversation_participant, conversation: another, account: account, user: agent)

        expect(subject).not_to permit(context, conversation)
      end
    end

    context 'when role grants conversation_participating_manage' do
      let(:custom_role) { create(:custom_role, account: account, permissions: ['conversation_participating_manage']) }

      before do
        agent_account_user.update!(role: :agent, custom_role: custom_role)
      end

      it 'allows access to conversations assigned to the agent' do
        conversation = create(:conversation, account: account, inbox: inbox, assignee: agent)

        expect(subject).to permit(context, conversation)
      end

      it 'allows access to conversations where the agent is a participant' do
        conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)
        create(:conversation_participant, conversation: conversation, account: account, user: agent)

        expect(subject).to permit(context, conversation)
      end

      it 'denies access to unrelated conversations' do
        conversation = create(:conversation, account: account, inbox: inbox, assignee: nil)

        expect(subject).not_to permit(context, conversation)
      end
    end
  end
end
