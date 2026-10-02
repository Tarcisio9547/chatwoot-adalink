require 'rails_helper'

# WhatsappParticipationCleanupListener tem que estar registrado no SyncDispatcher
# e vir ANTES do ActionCableListener: ele remove o responsável anterior dos
# participantes antes do broadcast síncrono do mesmo assignee_changed calcular
# quem pode ver a conversa (ver app/dispatchers/sync_dispatcher.rb).
describe SyncDispatcher do
  subject(:dispatcher) { described_class.new }

  describe '#listeners' do
    it 'includes WhatsappParticipationCleanupListener' do
      expect(dispatcher.listeners).to include(WhatsappParticipationCleanupListener.instance)
    end

    it 'includes ActionCableListener' do
      expect(dispatcher.listeners).to include(ActionCableListener.instance)
    end

    it 'runs WhatsappParticipationCleanupListener before ActionCableListener' do
      cleanup_index = dispatcher.listeners.index(WhatsappParticipationCleanupListener.instance)
      action_cable_index = dispatcher.listeners.index(ActionCableListener.instance)

      expect(cleanup_index).to be < action_cable_index
    end
  end
end
