require 'rails_helper'

# Adalink: correcao do juiz cego (rodada 2, item 2) - confere que o
# WhatsappParticipationCleanupListener esta registrado no SyncDispatcher e
# vem ANTES do ActionCableListener. A ordem importa: o cleanup listener
# precisa remover o responsavel anterior dos participantes antes do
# broadcast sincrono do proprio evento assignee_changed calcular quem pode
# ver a conversa (ver app/dispatchers/sync_dispatcher.rb).
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
