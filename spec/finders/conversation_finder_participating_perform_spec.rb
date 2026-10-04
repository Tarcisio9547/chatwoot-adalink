require 'rails_helper'

# A visão "Participando" (conversation_type=participating) também passa pelo
# PermissionFilterService: só entram as conversas em que o usuário é participante E que o papel
# dele permite listar. Antes ela ignorava o papel e listava tudo o que ele participa.
describe ConversationFinder, '#perform' do
  let!(:account) { create(:account) }
  let!(:inbox) { create(:inbox, account: account) }
  let!(:owner) { create(:user, account: account, role: :agent) }
  let!(:viewer) { create(:user, account: account, role: :agent) }
  let!(:shared) { create(:conversation, account: account, inbox: inbox, assignee: owner) }
  let!(:not_participating) { create(:conversation, account: account, inbox: inbox, assignee: owner) }
  let(:params) { { conversation_type: 'participating', status: 'all' } }

  before do
    Current.account = account
    create(:inbox_member, user: viewer, inbox: inbox)
    create(:conversation_participant, conversation: shared, account: account, user: viewer)
  end

  def ids_for(user)
    described_class.new(user, params).perform[:conversations].map(&:id)
  end

  def give_role(user, permissions)
    role = create(:custom_role, account: account, permissions: permissions)
    AccountUser.find_by(user: user, account: account).update!(role: :agent, custom_role: role)
  end

  it 'lists the conversations a regular agent participates in, and only those' do
    expect(ids_for(viewer)).to contain_exactly(shared.id)
    expect(ids_for(viewer)).not_to include(not_participating.id)
  end

  it 'lists them for an administrator who participates' do
    admin = create(:user, account: account, role: :administrator)
    create(:conversation_participant, conversation: shared, account: account, user: admin)

    expect(ids_for(admin)).to contain_exactly(shared.id)
  end

  %w[conversation_participating_manage conversation_unassigned_manage conversation_manage].each do |permission|
    it "lists the participating conversations for a custom role with #{permission}" do
      give_role(viewer, [permission])

      expect(ids_for(viewer)).to contain_exactly(shared.id)
    end
  end

  it 'lists a participating conversation of an inbox the user is not a member of (manager case)' do
    outsider = create(:user, account: account, role: :agent)
    create(:conversation_participant, conversation: shared, account: account, user: outsider)
    give_role(outsider, %w[conversation_participating_manage])

    expect(ids_for(outsider)).to contain_exactly(shared.id)
  end

  it 'lists nothing for a custom role with no conversation permission, even if he participates (the role filter now applies)' do
    give_role(viewer, %w[contact_manage])

    expect(ids_for(viewer)).to be_empty
  end

  it 'does not list participations of another account' do
    other_account = create(:account)
    create(:account_user, account: other_account, user: viewer, role: :agent)
    other_inbox = create(:inbox, account: other_account)
    foreign = create(:conversation, account: other_account, inbox: other_inbox)
    create(:conversation_participant, conversation: foreign, account: other_account, user: viewer)

    expect(ids_for(viewer)).to contain_exactly(shared.id)
  end

  it 'keeps the status filter working' do
    shared.update!(status: 'resolved')

    expect(described_class.new(viewer, conversation_type: 'participating', status: 'open').perform[:conversations]).to be_empty
    expect(described_class.new(viewer, conversation_type: 'participating', status: 'resolved').perform[:conversations].map(&:id)).to eq([shared.id])
  end
end
