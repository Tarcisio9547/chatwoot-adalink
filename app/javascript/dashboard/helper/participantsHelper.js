/**
 * Quem pode criar, alterar ou remover participantes de uma conversa.
 *
 * Espelha a regra do servidor (ConversationPolicy#manage_participants?): participar
 * dá acesso à conversa, então só mexe na lista quem é administrador, agente sem
 * custom_role (papel padrão do Chatwoot), custom_role com conversation_manage ("Todas")
 * ou o RESPONSÁVEL atual. Quem só enxerga a conversa (participante, "Minhas",
 * "Não atribuídas") não pode. O servidor é quem decide; isto só esconde o botão.
 *
 * @param {Object} params
 * @param {string} params.role - retorno de getUserRole ('administrator', 'agent' ou 'custom_role')
 * @param {Array<string>} params.permissions - permissões do usuário na conta
 * @param {number|string|null} [params.assigneeId] - id do responsável atual da conversa
 * @param {number|string} [params.currentUserId] - id do usuário logado
 * @returns {boolean}
 */
export const canManageParticipants = ({
  role,
  permissions = [],
  assigneeId = null,
  currentUserId = null,
}) => {
  if (['administrator', 'agent'].includes(role)) return true;
  if (permissions.includes('conversation_manage')) return true;

  return !!assigneeId && assigneeId === currentUserId;
};

/**
 * Quem pode REMOVER participantes. O responsável restrito adiciona mas não remove (senão o
 * corretor tiraria o gestor que o mark-work do CRM adicionou): só administrador, agente sem
 * custom_role e custom_role com conversation_manage ("Todas"). Espelha
 * ConversationPolicy#remove_participants? do servidor.
 *
 * @param {Object} params
 * @param {string} params.role - retorno de getUserRole ('administrator', 'agent' ou 'custom_role')
 * @param {Array<string>} params.permissions - permissões do usuário na conta
 * @returns {boolean}
 */
export const canRemoveParticipants = ({ role, permissions = [] }) =>
  ['administrator', 'agent'].includes(role) ||
  permissions.includes('conversation_manage');
