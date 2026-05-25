module Enterprise::Concerns::Article
  extend ActiveSupport::Concern

  included do
    after_save :add_article_embedding, if: -> { saved_change_to_title? || saved_change_to_description? || saved_change_to_content? }

    def self.add_article_embedding_association
      has_many :article_embeddings, dependent: :destroy_async
    end

    add_article_embedding_association

    def self.vector_search(params)
      embedding = Captain::Llm::EmbeddingService.new(account_id: params[:account_id]).get_embedding(params['query'])
      records = joins(
        :category
      ).search_by_category_slug(
        params[:category_slug]
      ).search_by_category_locale(params[:locale]).search_by_author(params[:author_id]).search_by_status(params[:status])
      filtered_article_ids = records.pluck(:id)

      # Fetch nearest neighbors and their distances, then filter directly

      # experimenting with filtering results based on result threshold
      # distance_threshold = 0.2
      # if using add the filter block to the below query
      # .filter { |ae| ae.neighbor_distance <= distance_threshold }

      article_ids = ArticleEmbedding.where(article_id: filtered_article_ids)
                                    .nearest_neighbors(:embedding, embedding, distance: 'cosine')
                                    .limit(5)
                                    .pluck(:article_id)

      # Fetch the articles by the IDs obtained from the nearest neighbors search
      where(id: article_ids)
    end
  end

  def add_article_embedding
    return unless account.feature_enabled?('help_center_embedding_search')

    Portal::ArticleIndexingJob.perform_later(self)
  end

  def generate_and_save_article_seach_terms
    terms = generate_article_search_terms
    article_embeddings.destroy_all
    terms.each { |term| article_embeddings.create!(term: term) }
  end

  def article_to_search_terms_prompt
    <<~SYSTEM_PROMPT_MESSAGE
      For the provided article content, generate potential search query keywords and snippets that can be used to generate the embeddings.
      Ensure the search terms are as diverse as possible but capture the essence of the article and are super related to the articles.
      Don't return any terms if there aren't any terms of relevance.
      Always return results in valid JSON of the following format
      {
        "search_terms": []
      }
    SYSTEM_PROMPT_MESSAGE
  end

  def generate_article_search_terms
    # ANTES: HTTParty direta pra api.openai.com + 'gpt-4o' hardcoded, fora da
    # abstração. Não respeitava preferência da account nem provider config.
    #
    # AGORA: passa pelo Llm::Config + RubyLLM. Modelo vem da preferência
    # `account.captain_assistant_model` (mesmo do Captain Assistant), com
    # fallback no DEFAULT_MODEL. Provider é resolvido via config/llm.yml.
    model = (account&.captain_assistant_model.presence || Llm::Config::DEFAULT_MODEL).to_s
    provider = Llm::Config.provider_for(model)

    api_key = search_terms_api_key(provider)
    raise 'No API key configured for article search terms generation' if api_key.blank?

    raw = Llm::Config.with_api_key(api_key, provider: provider) do |context|
      chat = context.chat(model: model, provider: provider)
      chat.with_instructions(article_to_search_terms_prompt)
      chat.with_params(response_format: { type: 'json_object' })
      chat.ask(article_search_terms_user_content).content
    end

    JSON.parse(raw)['search_terms']
  rescue StandardError => e
    Rails.logger.error("[Article#generate_article_search_terms] #{e.class}: #{e.message}")
    []
  end

  private

  def article_search_terms_user_content
    "title: #{title} \n description: #{description} \n content: #{content}"
  end

  # API key cascata: hook account-level pro provider > InstallationConfig system >
  # ENV (último recurso pra compat com setups antigos que só tinham OPENAI_API_KEY).
  def search_terms_api_key(provider)
    if account
      hook = account.hooks.find_by(app_id: Llm::Config.hook_app_id_for(provider), status: 'enabled')
      hook_key = hook&.settings&.dig('api_key')
      return hook_key if hook_key.present?
    end

    system_key, _ = Llm::Config.system_credentials_for(provider)
    return system_key if system_key.present?

    # Retrocompat: muitos setups antigos só tinham OPENAI_API_KEY no ENV
    return ENV.fetch('OPENAI_API_KEY', nil) if provider == 'openai'

    nil
  end
end
