import {
  canManageParticipants,
  canRemoveParticipants,
} from '../participantsHelper';

// Mesma regra do servidor (ConversationPolicy#manage_participants?): administrador,
// agente sem custom_role, custom_role com conversation_manage ("Todas") ou o
// RESPONSÁVEL atual. Quem só enxerga a conversa (participante, "Minhas",
// "Não atribuídas") não gerencia a lista.
describe('participantsHelper', () => {
  describe('#canManageParticipants', () => {
    const base = { permissions: [], assigneeId: 2, currentUserId: 1 };

    it('permite ao administrador', () => {
      expect(canManageParticipants({ ...base, role: 'administrator' })).toBe(
        true
      );
    });

    it('permite ao agente sem custom_role (papel padrão do Chatwoot)', () => {
      expect(canManageParticipants({ ...base, role: 'agent' })).toBe(true);
    });

    it('permite ao custom_role com conversation_manage ("Todas")', () => {
      expect(
        canManageParticipants({
          ...base,
          role: 'custom_role',
          permissions: ['conversation_manage'],
        })
      ).toBe(true);
    });

    describe.each([
      ['Minhas', ['conversation_participating_manage']],
      ['Não atribuídas', ['conversation_unassigned_manage']],
    ])('com a visão restrita %s', (_nome, permissions) => {
      const restrito = { ...base, role: 'custom_role', permissions };

      it('nega quando ele não é o responsável', () => {
        expect(canManageParticipants(restrito)).toBe(false);
      });

      it('nega em conversa sem responsável', () => {
        expect(canManageParticipants({ ...restrito, assigneeId: null })).toBe(
          false
        );
        expect(
          canManageParticipants({ ...restrito, assigneeId: undefined })
        ).toBe(false);
      });

      it('permite ao responsável atual', () => {
        expect(canManageParticipants({ ...restrito, assigneeId: 1 })).toBe(
          true
        );
      });
    });

    it('nega ao custom_role sem nenhuma permissão de conversa', () => {
      expect(
        canManageParticipants({
          ...base,
          role: 'custom_role',
          permissions: ['contact_manage'],
        })
      ).toBe(false);
    });

    it('nega sem usuário atual, mesmo com conversa sem responsável', () => {
      expect(
        canManageParticipants({
          role: 'custom_role',
          permissions: [],
          assigneeId: undefined,
          currentUserId: undefined,
        })
      ).toBe(false);
    });
  });

  // O responsável restrito adiciona participantes mas não remove (senão o corretor tiraria o gestor
  // que o mark-work do CRM adicionou). Remover: administrador, agente sem custom_role e "Todas".
  describe('#canRemoveParticipants', () => {
    it('permite ao administrador, ao agente sem custom_role e a "Todas"', () => {
      expect(canRemoveParticipants({ role: 'administrator' })).toBe(true);
      expect(canRemoveParticipants({ role: 'agent' })).toBe(true);
      expect(
        canRemoveParticipants({
          role: 'custom_role',
          permissions: ['conversation_manage'],
        })
      ).toBe(true);
    });

    it.each([
      ['Minhas', ['conversation_participating_manage']],
      ['Não atribuídas', ['conversation_unassigned_manage']],
    ])(
      'nega à visão restrita %s, mesmo sendo o responsável',
      (_nome, permissions) => {
        expect(
          canRemoveParticipants({
            role: 'custom_role',
            permissions,
            assigneeId: 1,
            currentUserId: 1,
          })
        ).toBe(false);
      }
    );

    it('nega ao custom_role sem permissão de conversa', () => {
      expect(
        canRemoveParticipants({
          role: 'custom_role',
          permissions: ['contact_manage'],
        })
      ).toBe(false);
    });
  });
});
