# O Enterprise::Captain::BaseTaskService devolve error_code :conversation_not_visible
# quando o usuário não enxerga a conversa (caixa WhatsApp, pelo papel). Aqui isso
# vira 404, sem corpo, igual a uma conversa que não existe pra ele.
module Enterprise::Api::V1::Accounts::Captain::TasksController
  private

  def render_result(result)
    return head :not_found if result.is_a?(Hash) && result[:error_code] == :conversation_not_visible

    super
  end
end
