# frozen_string_literal: true

require 'pathname'

module ChatwootApp
  def self.root
    Pathname.new(File.expand_path('..', __dir__))
  end

  def self.max_limit
    100_000
  end

  def self.enterprise?
    true
  end

  def self.chatwoot_cloud?
    false
  end

  def self.self_hosted_enterprise?
    true
  end

  def self.custom?
    @custom ||= root.join('custom').exist?
  end

  def self.help_center_root
    ENV.fetch('HELPCENTER_URL', nil) || ENV.fetch('FRONTEND_URL', nil)
  end

  # `enterprise?` desbloqueia as FEATURES enterprise (licenciamento), mas neste fork
  # o código das features enterprise foi movido para dentro dos namespaces normais
  # (ex.: enterprise/lib/captain/response_schema.rb define `Captain::ResponseSchema`,
  # não `Enterprise::Captain::ResponseSchema`) — não existe nenhum `module Enterprise`
  # neste repositório. `extensions` alimenta InjectEnterpriseEditionModule
  # (config/initializers/01_inject_enterprise_edition_module.rb), que resolve
  # `Enterprise::<algo>` para fazer prepend/extend/include condicional. Incluir
  # 'enterprise' aqui sem o namespace existir faz `const_get_maybe_false` (bug do
  # próprio Chatwoot: `mod&.const_defined?` só protege contra nil, não contra o
  # `false` que ele mesmo retorna) explodir com NoMethodError sempre que alguma
  # classe com `prepend_mod_with` for autoloaded num contexto que expõe o timing
  # certo — foi o que travava o CI (ver PR de fix). custom?/'custom' segue igual:
  # aponta pro namespace Custom real, que aí sim existe quando a pasta custom/ existe.
  def self.extensions
    if custom?
      %w[custom]
    else
      %w[]
    end
  end

  def self.advanced_search_allowed?
    enterprise? && ENV.fetch('OPENSEARCH_URL', nil).present?
  end

  def self.otel_enabled?
    otel_provider = InstallationConfig.find_by(name: 'OTEL_PROVIDER')&.value
    secret_key = InstallationConfig.find_by(name: 'LANGFUSE_SECRET_KEY')&.value

    otel_provider.present? && secret_key.present? && otel_provider == 'langfuse'
  end
end
