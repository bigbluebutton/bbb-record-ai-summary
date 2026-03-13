# LLM Client abstraction for multiple providers
require 'yaml'
require 'json'
require 'net/http'

module LLMClient
  class Base
    attr_reader :config, :provider_config

    def self.get_config_path()
      # Load LLM configuration — works in both dev and production
      bbb_core = '/usr/local/bigbluebutton/core'
      llm_config_path = if __dir__.start_with?("#{bbb_core}")
        "#{bbb_core}/lib/ai-summary/llm.yml"
      else
        raise "Run summarization only in production."
      end

      unless File.exist?(llm_config_path)
        logger.warn("LLM config not found at #{llm_config_path}, skipping summarization")
        return nil
      end
      return llm_config_path
    end

    # Recursively merges +override+ into +base+, combining nested hashes
    # key-by-key so that only the keys present in +override+ are changed.
    def self.deep_merge_hashes(base, override)
      base.merge(override) do |_key, base_val, override_val|
        if base_val.is_a?(Hash) && override_val.is_a?(Hash)
          deep_merge_hashes(base_val, override_val)
        else
          override_val
        end
      end
    end

    # Loads llm.yml from +config_path+ and applies an optional operator override
    # from /etc/bigbluebutton/ai-summary-llm.yml.
    def self.load_llm_config(config_path, logger)
      config = YAML.load_file(config_path)

      override_path = '/etc/bigbluebutton/ai-summary-llm.yml'
      if File.exist?(override_path)
        override = YAML.safe_load(File.read(override_path)) || {}
        config = deep_merge_hashes(config, override)
        logger.info("Applied LLM config override from #{override_path}")
      end

      config
    end

    def self.create(logger, language: nil)
      llm_config_path = get_config_path()

      config = load_llm_config(llm_config_path, logger)
      provider = config['provider']
      logger.info("LLM provider: #{provider}")

      # llm.yml 'language' overrides the transcription-detected language
      config_language = config['language'].to_s.strip
      effective_language = config_language.empty? ? language : config_language
      effective_language = nil if effective_language.to_s.empty?

      case provider
      when 'claude'
        ClaudeClient.new(config, logger, language: effective_language)
      when 'openai'
        OpenAIClient.new(config, logger, language: effective_language)
      when 'albert'
        AlbertClient.new(config, logger, language: effective_language)
      when 'disabled'
        logger.info("LLM summary is disabled")
        DisabledClient.new(config, logger)
      else
        raise "Unknown LLM provider: #{provider}. Use 'claude', 'openai', 'albert', or 'disabled'"
      end
    end

    def initialize(config, logger, language: nil)
      @config = config
      @logger = logger
      @language = language
      @provider_config = config[@config['provider']] || {}
      if @provider_config.empty?
        @logger.warn("No '#{@config['provider']}:' section found in llm.yml — provider-specific settings (model, max_tokens, temperature) will use hardcoded defaults")
      end
    end

    def summarize(text)
      raise NotImplementedError, "Subclass must implement summarize method"
    end

    protected

    def system_prompt
      base = @config['system_prompt'] || "Summarize the following meeting content."
      return base.rstrip unless @language && !@language.empty?

      "#{base.rstrip}\n\nWrite your entire response in the language with ISO 639-1 code '#{@language}'."
    end
  end

  class DisabledClient < Base
    def summarize(text)
      nil  # Return nil when disabled
    end
  end

  class ClaudeClient < Base
    API_URL = 'https://api.anthropic.com/v1/messages'.freeze
    API_VERSION = '2023-06-01'.freeze
    DEFAULT_MODEL = 'claude-3-5-sonnet-20241022'.freeze

    def initialize(config, logger, language: nil)
      super
      @api_key = ENV['ANTHROPIC_API_KEY'] || @config['anthropic_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "Anthropic API key not found. Set ANTHROPIC_API_KEY environment variable or add to /usr/local/bigbluebutton/core/scripts/ai-summary/llm.yml"
      end
    end

    def summarize(text)
      model = @provider_config['model'] || DEFAULT_MODEL
      @logger.info("Claude model: #{model}")
      body = {
        model: model,
        max_tokens: @provider_config['max_tokens'] || 1024,
        temperature: @provider_config['temperature'] || 0.7,
        system: system_prompt,
        messages: [{ role: 'user', content: text }]
      }

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request['x-api-key'] = @api_key
      request['anthropic-version'] = API_VERSION
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

      result = JSON.parse(response.body)
      raise "Claude API error: #{result['error']['message']}" if result['error']

      result.dig('content', 0, 'text')
    rescue Net::HTTPError => e
      raise "Claude API error: #{e.message}"
    end
  end

  class OpenAIClient < Base
    API_URL = 'https://api.openai.com/v1/chat/completions'.freeze
    DEFAULT_MODEL = 'gpt-4o-mini'.freeze

    def initialize(config, logger, language: nil)
      super
      @api_key = ENV['OPENAI_API_KEY'] || @config['openai_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "OpenAI API key not found. Set OPENAI_API_KEY environment variable or add to config/llm.yml"
      end
    end

    def summarize(text)
      model = @provider_config['model'] || DEFAULT_MODEL
      @logger.info("OpenAI model: #{model}")
      body = {
        model: model,
        messages: [
          { role: 'system', content: system_prompt },
          { role: 'user', content: text }
        ]
      }

      body[:max_tokens] = @provider_config['max_tokens'] unless @provider_config['max_tokens'].nil?
      body[:temperature] = @provider_config['temperature'] unless @provider_config['temperature'].nil?

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@api_key}"
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

      result = JSON.parse(response.body)
      raise "OpenAI API error: #{result.dig('error', 'message')}" if result['error']

      result.dig('choices', 0, 'message', 'content')
    rescue Net::HTTPError => e
      raise "OpenAI API error: #{e.message}"
    end
  end

  class AlbertClient < Base
    API_URL = 'https://albert.api.etalab.gouv.fr/v1/chat/completions'.freeze
    DEFAULT_MODEL = 'AgentPublic/llama3-instruct-8b'.freeze

    def initialize(config, logger, language: nil)
      super
      @api_key = ENV['ALBERT_API_KEY'] || @config['albert_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "Albert API key not found. Set ALBERT_API_KEY environment variable or add albert_api_key to llm.yml"
      end
    end

    def summarize(text)
      model = @provider_config['model'] || DEFAULT_MODEL
      @logger.info("Albert model: #{model}")
      body = {
        model: model,
        messages: [
          { role: 'system', content: system_prompt },
          { role: 'user', content: text }
        ]
      }

      body[:max_tokens] = @provider_config['max_tokens'] unless @provider_config['max_tokens'].nil?
      body[:temperature] = @provider_config['temperature'] unless @provider_config['temperature'].nil?

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@api_key}"
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        raise "Albert API HTTP #{response.code}: #{response.body[0...500]}"
      end

      result = JSON.parse(response.body)
      raise "Albert API error: #{result.dig('error', 'message')}" if result['error']

      content = result.dig('choices', 0, 'message', 'content')
      if content.nil? || content.strip.empty?
        finish_reason = result.dig('choices', 0, 'finish_reason')
        @logger.warn("Albert returned empty content (finish_reason=#{finish_reason.inspect}). Full response: #{response.body[0...500]}")
      end
      content
    rescue Net::HTTPError => e
      raise "Albert API error: #{e.message}"
    end
  end
end
