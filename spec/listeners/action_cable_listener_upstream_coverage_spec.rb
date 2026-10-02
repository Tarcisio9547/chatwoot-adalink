require 'rails_helper'
require 'method_source'

# Spec guarda: lê o código-fonte de cada método público do ActionCableListener
# upstream e confere que todo método que usa `inbox.members` está coberto por
# Enterprise::ActionCableListener (override direto, ou around_member_filtering +
# o ponto único de filtragem em user_tokens). Um evento novo do Chatwoot que use
# inbox.members sem cobertura quebra este teste, em vez de vazar conversas de
# outros corretores em silêncio.
# rubocop:disable RSpec/DescribeClass -- guard le/compara DUAS classes
# (ActionCableListener upstream x Enterprise::ActionCableListener), nao ha
# uma unica classe alvo natural para o primeiro argumento do describe.
describe 'ActionCableListener upstream coverage (role visibility guard)' do
  # Metodos que broadcastam por conta inteira, por usuario-alvo ou dados de
  # notificacao - nao dependem de conversation.inbox.members, entao nao
  # precisam de cobertura de papel.
  def methods_without_inbox_members
    %w[
      notification_created notification_updated notification_deleted
      account_cache_invalidated contact_created contact_updated contact_merged
      contact_deleted conversation_mentioned
    ]
  end

  def public_event_methods
    ActionCableListener.public_instance_methods(false).map(&:to_s)
  end

  # Adalink: ActionCableListener.prepend_mod_with('ActionCableListener') prepende
  # Enterprise::ActionCableListener na cadeia de ancestrais, entao
  # ActionCableListener.instance_method(m) resolve pra implementacao MAIS
  # DERIVADA (a do modulo enterprise), nao a original upstream. Subimos via
  # super_method ate achar o Method cujo owner e a propria classe base, que e
  # o codigo-fonte upstream de verdade que este guard precisa inspecionar.
  def upstream_method_source(method_name)
    method_obj = ActionCableListener.instance_method(method_name)
    method_obj = method_obj.super_method while method_obj && method_obj.owner != ActionCableListener
    return '' if method_obj.nil?

    method_obj.source
  rescue MethodSource::SourceNotFoundError
    ''
  end

  # Segue transitivamente: se o corpo chama outro metodo privado da PROPRIA
  # classe upstream (ex.: conversation_typing_on -> typing_event_listener_tokens),
  # inspeciona o corpo desse metodo tambem. Assim um metodo que so usa
  # inbox.members indiretamente (via um helper privado) nao escapa do guard.
  def uses_inbox_members?(source, visited = Set.new)
    return true if source.include?('inbox.members')

    private_methods_called_in(source).any? do |called_method|
      next false if visited.include?(called_method)

      visited << called_method
      uses_inbox_members?(upstream_method_source(called_method), visited)
    end
  end

  def private_methods_called_in(source)
    private_method_names = (ActionCableListener.private_instance_methods(false) + ActionCableListener.instance_methods(false)).map(&:to_s)
    private_method_names.select { |name| source.match?(/\b#{Regexp.escape(name)}\(/) }
  end

  it 'has at least one event that depends on inbox.members (sanity check the guard is meaningful)' do
    methods_using_inbox_members = public_event_methods.select { |m| uses_inbox_members?(upstream_method_source(m)) }

    expect(methods_using_inbox_members).not_to be_empty
  end

  it 'covers every upstream public method that reads conversation.inbox.members via the enterprise module' do
    methods_using_inbox_members = public_event_methods.select { |m| uses_inbox_members?(upstream_method_source(m)) }

    enterprise_module = Enterprise::ActionCableListener
    enterprise_overrides = enterprise_module.public_instance_methods(false).map(&:to_s) +
                           enterprise_module.private_instance_methods(false).map(&:to_s)

    uncovered = methods_using_inbox_members - enterprise_overrides

    expect(uncovered).to be_empty,
                         "Metodo(s) upstream usando inbox.members sem override/wrapper no modulo enterprise: #{uncovered.join(', ')}. " \
                         'Um evento novo do Chatwoot com inbox.members precisa entrar em around_member_filtering ' \
                         '(enterprise/app/listeners/enterprise/action_cable_listener.rb) ou ganhar tratamento proprio.'
  end

  it 'accounts for every public method: either uses inbox.members (covered above) or is explicitly exempt' do
    accounted_for = public_event_methods.select { |m| uses_inbox_members?(upstream_method_source(m)) }
    unaccounted = public_event_methods - accounted_for - methods_without_inbox_members

    expect(unaccounted).to be_empty,
                           "Metodo(s) publico(s) novo(s) no ActionCableListener upstream, nao classificados: #{unaccounted.join(', ')}. " \
                           'Adicione a methods_without_inbox_members (se nao depende de papel) ou confirme que entra na cobertura acima.'
  end
end
# rubocop:enable RSpec/DescribeClass
