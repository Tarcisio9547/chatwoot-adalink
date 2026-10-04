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

  # Atribuição: quem tem visão restrita (custom_role sem conversation_manage) só se atribui a uma
  # conversa SEM responsável e só reatribui/tira o responsável se ele mesmo for o responsável atual.
  describe '#change_assignee?' do
    let(:other_agent) { create(:user, account: account, role: :agent) }
    let(:owned) { create(:conversation, account: account, inbox: inbox, assignee: other_agent) }
    let(:ownerless) { create(:conversation, account: account, inbox: inbox, assignee: nil) }
    let(:mine) { create(:conversation, account: account, inbox: inbox, assignee: agent) }

    def allowed?(conversation, target)
      described_class.new(context, conversation).change_assignee?(target)
    end

    def restrict!(permission)
      role = create(:custom_role, account: account, permissions: [permission])
      agent_account_user.update!(role: :agent, custom_role: role)
    end

    %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
      context "with the restricted visibility #{permission}" do
        before do
          restrict!(permission)
          create(:conversation_participant, conversation: ownerless, account: account, user: agent) # precisa enxergar a conversa
        end

        it 'takes an ownerless conversation for himself (id as number or text)' do
          expect(allowed?(ownerless, agent.id)).to be true
          expect(allowed?(ownerless, agent.id.to_s)).to be true
        end

        it 'does not give an ownerless conversation to someone else, nor to nobody' do
          expect(allowed?(ownerless, other_agent.id)).to be false
          expect(allowed?(ownerless, nil)).to be false
        end

        it 'does not take, hand over or drop a conversation that has another owner' do
          expect(allowed?(owned, agent.id)).to be false
          expect(allowed?(owned, other_agent.id)).to be false
          expect(allowed?(owned, nil)).to be false
        end

        it 'hands over or drops a conversation he owns' do
          expect(allowed?(mine, other_agent.id)).to be true
          expect(allowed?(mine, nil)).to be true
          expect(allowed?(mine, agent.id)).to be true
        end
      end
    end

    it 'allows everything to an administrator, even with a leftover custom_role' do
      role = create(:custom_role, account: account, permissions: %w[conversation_unassigned_manage])
      agent_account_user.update_columns(role: AccountUser.roles[:administrator], custom_role_id: role.id) # rubocop:disable Rails/SkipsModelValidations

      expect(allowed?(owned, agent.id)).to be true
      expect(allowed?(owned, nil)).to be true
    end

    it 'allows everything to an agent without custom role' do
      expect(allowed?(owned, agent.id)).to be true
      expect(allowed?(owned, nil)).to be true
    end

    it 'allows everything to the "Todas" role (conversation_manage)' do
      restrict!('conversation_manage')

      expect(allowed?(owned, agent.id)).to be true
      expect(allowed?(owned, nil)).to be true
    end

    it 'does not restrict an agent bot' do
      bot = create(:agent_bot)
      bot_policy = described_class.new({ user: bot, account: account, account_user: nil }, owned)

      expect(bot_policy.change_assignee?(other_agent.id)).to be true
    end

    it 'denies when there is no account_user (same as manage_participants?)' do
      no_account_user = described_class.new({ user: agent, account: account, account_user: nil }, ownerless)

      expect(no_account_user.change_assignee?(agent.id)).to be false
      expect(no_account_user.manage_participants?).to be false
    end

    it 'also requires seeing the conversation (show?), whatever the role' do
      hidden_inbox = create(:inbox, account: account)
      hidden = create(:conversation, account: account, inbox: hidden_inbox, assignee: nil)

      expect(allowed?(hidden, agent.id)).to be false # agente sem papel, fora da caixa
      restrict!('conversation_unassigned_manage')
      expect(allowed?(hidden, agent.id)).to be false # restrito, fora da caixa

      create(:conversation_participant, conversation: hidden, account: account, user: agent)
      expect(allowed?(hidden, agent.id)).to be true # participante enxerga
    end

    it 'still lets an administrator change the owner of a conversation of any inbox' do
      hidden = create(:conversation, account: account, inbox: create(:inbox, account: account), assignee: other_agent)
      agent_account_user.update!(role: :administrator)

      expect(allowed?(hidden, agent.id)).to be true
    end
  end

  # Trocar o time pode trocar o responsável (o AssignmentHandler zera o dono que não é do time novo e
  # o round-robin pode entregar a conversa). Para visão restrita, só passa se a troca de responsável
  # que ela causaria também passaria.
  describe '#change_team?' do
    let(:scene) do
      owner = create(:user, account: account, role: :agent)
      team_with_owner = create(:team, account: account, allow_auto_assign: false)
      create(:team_member, team: team_with_owner, user: owner)
      {
        owned: create(:conversation, account: account, inbox: inbox, assignee: owner),
        mine: create(:conversation, account: account, inbox: inbox, assignee: agent),
        ownerless: create(:conversation, account: account, inbox: inbox, assignee: nil),
        team_with_owner: team_with_owner,
        team_without_owner: create(:team, account: account, allow_auto_assign: false),
        auto_team: create(:team, account: account, allow_auto_assign: true)
      }
    end

    def team_allowed?(conversation, team)
      described_class.new(context, conversation).change_team?(team)
    end

    context 'with a restricted visibility' do
      before do
        role = create(:custom_role, account: account, permissions: %w[conversation_participating_manage])
        agent_account_user.update!(role: :agent, custom_role: role)
        %i[owned ownerless].each do |name|
          create(:conversation_participant, conversation: scene[name], account: account, user: agent)
        end
      end

      it 'allows no team (removing it) and a team that keeps the owner' do
        expect(team_allowed?(scene[:owned], nil)).to be true
        expect(team_allowed?(scene[:owned], scene[:team_with_owner])).to be true
      end

      it 'denies a team that would clear the owner of someone else' do
        expect(team_allowed?(scene[:owned], scene[:team_without_owner])).to be false
      end

      it 'allows the owner to move his own conversation to any team' do
        expect(team_allowed?(scene[:mine], scene[:team_without_owner])).to be true
      end

      it 'denies an auto-assign team on an ownerless conversation, allows a plain team' do
        expect(team_allowed?(scene[:ownerless], scene[:auto_team])).to be false
        expect(team_allowed?(scene[:ownerless], scene[:team_without_owner])).to be true
      end

      it 'denies when he cannot even see the conversation' do
        hidden = create(:conversation, account: account, inbox: create(:inbox, account: account), assignee: nil)

        expect(team_allowed?(hidden, scene[:team_without_owner])).to be false
      end
    end

    it 'allows everything to an agent without custom role and to the "Todas" role' do
      expect(team_allowed?(scene[:owned], scene[:team_without_owner])).to be true

      role = create(:custom_role, account: account, permissions: %w[conversation_manage])
      agent_account_user.update!(role: :agent, custom_role: role)
      expect(team_allowed?(scene[:owned], scene[:team_without_owner])).to be true
    end
  end

  # Quem só é o responsável restrito pode ADICIONAR participantes, mas não REMOVER (senão o corretor
  # tiraria o gestor que o mark-work do CRM adicionou). Remover: administrador, agente sem papel e
  # "Todas".
  describe '#remove_participants?' do
    let(:other_agent) { create(:user, account: account, role: :agent) }
    let(:mine) { create(:conversation, account: account, inbox: inbox, assignee: agent) }
    let(:owned) { create(:conversation, account: account, inbox: inbox, assignee: other_agent) }

    def restrict!(permission)
      role = create(:custom_role, account: account, permissions: [permission])
      agent_account_user.update!(role: :agent, custom_role: role)
    end

    def can_remove?(conversation)
      described_class.new(context, conversation).remove_participants?
    end

    %w[conversation_participating_manage conversation_unassigned_manage].each do |permission|
      it "denies the restricted (#{permission}) owner, who can still add" do
        restrict!(permission)

        expect(can_remove?(mine)).to be false
        expect(described_class.new(context, mine).manage_participants?).to be true
      end

      it "denies the restricted (#{permission}) participant" do
        restrict!(permission)
        create(:conversation_participant, conversation: owned, account: account, user: agent)

        expect(can_remove?(owned)).to be false
      end
    end

    it 'allows an agent without custom role, the "Todas" role and an administrator' do
      expect(can_remove?(owned)).to be true

      restrict!('conversation_manage')
      expect(can_remove?(owned)).to be true

      agent_account_user.update!(role: :administrator)
      expect(can_remove?(owned)).to be true
    end

    it 'denies an agent bot and a user without account_user' do
      bot = create(:agent_bot)

      expect(described_class.new({ user: bot, account: account, account_user: nil }, owned).remove_participants?).to be false
      expect(described_class.new({ user: agent, account: account, account_user: nil }, owned).remove_participants?).to be false
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
