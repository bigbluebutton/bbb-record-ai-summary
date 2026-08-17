# LLM Client abstraction for multiple providers
require 'yaml'
require 'json'
require 'net/http'

module LLMClient
  # Raised when the remote provider (Albert/Claude/OpenAI) is at fault: a non-2xx
  # response, a malformed body, an empty completion, or a transport failure.
  # Carries the provider name and HTTP status so logs can name the culprit.
  class ProviderError < StandardError
    attr_reader :provider, :http_status

    def initialize(message, provider: nil, http_status: nil)
      @provider = provider
      @http_status = http_status
      super(message)
    end
  end

  # Raised when this server is misconfigured: missing API key, unknown provider,
  # unreadable ai-summary.yml. Neither the provider's fault nor a code defect.
  class ConfigError < StandardError; end

  class Base
    attr_reader :config, :provider_config

    # Every LLM call made in this process, in order:
    #   { op:, provider:, model:, ms:, ok:, error_class: }
    # The process stage aggregates this into its timings and metrics line.
    def self.call_log
      @call_log ||= []
    end

    def self.reset_call_log
      @call_log = []
    end

    # The provider `create` last resolved from the config. call_log already
    # carries the provider on every call, including DisabledClient's no-ops, but
    # a client that raises in its constructor (missing API key, unknown provider)
    # never reaches a call — this keeps the provider knowable in that case too.
    class << self
      attr_accessor :configured_provider
    end

    def self.monotonic_ms
      (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
    end

    # Sorts an exception into the three buckets an operator needs to triage:
    # PROVIDER_ERROR (call the provider), CONFIG_ERROR (fix this server),
    # MODULE_ERROR (file a bug against this module).
    def self.classify(error)
      case error
      when ProviderError then 'PROVIDER_ERROR'
      when ConfigError   then 'CONFIG_ERROR'
      when Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
           Errno::ECONNREFUSED, EOFError, SocketError, JSON::ParserError
        'PROVIDER_ERROR'
      else 'MODULE_ERROR'
      end
    end

    # Retry transient LLM API failures (rate limits, 5xx, timeouts) a few times
    # with exponential backoff before giving up.
    MAX_RETRIES     = 3
    RETRYABLE_CODES = %w[429 500 502 503 504].freeze
    OPEN_TIMEOUT    = 15
    READ_TIMEOUT    = 180

    def self.get_config_path(logger)
      bbb_core = '/usr/local/bigbluebutton/core'
      config_path = if __dir__.start_with?(bbb_core)
        "#{bbb_core}/scripts/ai-summary.yml"
      else
        # Dev mode: look for config relative to project root
        dev_config = File.expand_path('../../../src/ai-summary.yml', __dir__)
        dev_config = File.expand_path('../../../src/ai-summary/ai-summary.yml', __dir__) unless File.exist?(dev_config)
        dev_config
      end

      unless File.exist?(config_path)
        logger.warn("ai-summary.yml not found at #{config_path}, skipping summarization")
        return nil
      end
      config_path
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

    # Loads the llm: section from ai-summary.yml
    def self.load_llm_config(config_path, logger)
      full_config = YAML.load_file(config_path)

      override_path = '/etc/bigbluebutton/ai-summary.yml'
      if File.exist?(override_path)
        override = YAML.safe_load(File.read(override_path)) || {}
        full_config = deep_merge_hashes(full_config, override)
        logger.info("Applied config override from #{override_path}")
      end

      full_config['llm'] || { 'provider' => 'disabled' }
    end

    def self.create(logger, language: nil, prompt_addition: nil)
      llm_config_path = get_config_path(logger)

      config = load_llm_config(llm_config_path, logger)
      provider = config['provider']
      Base.configured_provider = provider
      logger.info("LLM provider: #{provider}")

      # llm.yml 'language' overrides the transcription-detected language
      config_language = config['language'].to_s.strip
      effective_language = config_language.empty? ? language : config_language
      effective_language = nil if effective_language.to_s.empty?

      case provider
      when 'claude'
        ClaudeClient.new(config, logger, language: effective_language, prompt_addition: prompt_addition)
      when 'openai'
        OpenAIClient.new(config, logger, language: effective_language, prompt_addition: prompt_addition)
      when 'albert'
        AlbertClient.new(config, logger, language: effective_language, prompt_addition: prompt_addition)
      when 'disabled'
        logger.info("LLM summary is disabled")
        DisabledClient.new(config, logger)
      else
        raise ConfigError, "Unknown LLM provider: #{provider}. Use 'claude', 'openai', 'albert', or 'disabled'"
      end
    end

    def initialize(config, logger, language: nil, prompt_addition: nil)
      @config = config
      @logger = logger
      @language = language
      @prompt_addition = prompt_addition
      @provider_config = config[@config['provider']] || {}
      if @provider_config.empty?
        @logger.warn("No '#{@config['provider']}:' section found in llm.yml — provider-specific settings (model, max_tokens, temperature) will use hardcoded defaults")
      end
    end

    def summarize(text)
      timed('summary') { chat_completion(system: system_prompt, user: text) }
    end

    # Run a completion with an explicit system prompt. Used for structured
    # extraction (e.g. action items) that needs its own instructions rather than
    # the meeting-summary system prompt.
    def complete(user, system:)
      timed('action_items') { chat_completion(system: system, user: user) }
    end

    def provider_name
      @config['provider'].to_s
    end

    protected

    # Times one logical LLM call and records it in Base.call_log. Wrapping here
    # rather than at the call sites means retries and map-reduce sub-calls are
    # counted too, and a failed call still contributes its duration.
    def timed(op)
      started = Base.monotonic_ms
      result = yield
      elapsed = Base.monotonic_ms - started
      Base.call_log << { op: op, provider: provider_name, model: @provider_config['model'],
                         ms: elapsed, ok: true }
      @logger.info("LLM call op=#{op} provider=#{provider_name} model=#{@provider_config['model']} ms=#{elapsed} outcome=ok")
      result
    rescue StandardError => e
      elapsed = Base.monotonic_ms - started
      Base.call_log << { op: op, provider: provider_name, model: @provider_config['model'],
                         ms: elapsed, ok: false, error_class: e.class.name }
      @logger.warn("LLM call op=#{op} provider=#{provider_name} ms=#{elapsed} outcome=failed error_class=#{e.class}")
      raise
    end

    # Subclasses perform one chat/messages call and return the text content.
    def chat_completion(system:, user:)
      raise NotImplementedError, "Subclass must implement chat_completion"
    end

    # Parses a provider response body, reporting a non-JSON body (an HTML error
    # page from a gateway, say) as a provider fault rather than letting
    # JSON::ParserError surface and read like a defect in this module.
    def parse_provider_json(response)
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      raise ProviderError.new(
        "#{provider_name} returned a non-JSON body (content-type=#{response['content-type']}): #{response.body.to_s[0, 300]}",
        provider: provider_name, http_status: response.code
      )
    end

    # POSTs +request+ to +uri+ with explicit timeouts, retrying on transient
    # errors (429/5xx and connection/timeout errors) with exponential backoff.
    # Returns the final Net::HTTPResponse; the caller checks it for success.
    def http_post_with_retry(uri, request)
      last_response = nil

      (0..MAX_RETRIES).each do |attempt|
        begin
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                     open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
            http.request(request)
          end
          unless RETRYABLE_CODES.include?(response.code)
            # 400/401/403/404 are not worth retrying, but they are the most
            # common provider-side faults (bad key, unknown model) and used to
            # leave no trace at all in the log.
            unless response.is_a?(Net::HTTPSuccess)
              @logger.error("#{provider_name} API non-retryable HTTP #{response.code} from #{uri.host} — not retrying")
            end
            return response
          end

          last_response = response
          @logger.warn("#{provider_name} API returned HTTP #{response.code} (attempt #{attempt + 1}/#{MAX_RETRIES + 1})")
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET,
               Errno::ECONNREFUSED, EOFError, SocketError => e
          @logger.warn("#{provider_name} API transient error #{e.class}: #{e.message} (attempt #{attempt + 1}/#{MAX_RETRIES + 1})")
          raise if attempt == MAX_RETRIES
        end

        sleep(2**attempt) if attempt < MAX_RETRIES
      end

      last_response
    end

    def system_prompt
      base = @config['system_prompt'] || "Summarize the following meeting content."
      result = base.rstrip
      result = "#{result}\n\nWrite your entire response in the language with ISO 639-1 code '#{@language}'." if @language && !@language.empty?
      result = "#{result}\n\n#{@prompt_addition.strip}" if @prompt_addition && !@prompt_addition.strip.empty?
      result
    end
  end

  class DisabledClient < Base
    def chat_completion(system:, user:)
      nil  # Return nil when disabled
    end
  end

  class ClaudeClient < Base
    API_URL = 'https://api.anthropic.com/v1/messages'.freeze
    API_VERSION = '2023-06-01'.freeze
    DEFAULT_MODEL = 'claude-opus-5'.freeze

    def initialize(config, logger, language: nil, prompt_addition: nil)
      super
      @api_key = ENV['ANTHROPIC_API_KEY'] || @config['anthropic_api_key']

      if @api_key.nil? || @api_key.empty?
        raise ConfigError, "Anthropic API key not found. Set ANTHROPIC_API_KEY environment variable or add to /usr/local/bigbluebutton/core/scripts/ai-summary/llm.yml"
      end
    end

    def chat_completion(system:, user:)
      model = @provider_config['model'] || DEFAULT_MODEL
      @logger.info("Claude model: #{model}")
      max_tokens = @provider_config['max_tokens'] || 1024
      body = {
        model: model,
        max_tokens: max_tokens,
        system: system,
        messages: [{ role: 'user', content: user }]
      }

      # Only send temperature when the operator asked for one: the Claude 5 family
      # (claude-opus-5, claude-sonnet-5, ...) rejects sampling parameters with a 400.
      body[:temperature] = @provider_config['temperature'] unless @provider_config['temperature'].nil?

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request['x-api-key'] = @api_key
      request['anthropic-version'] = API_VERSION
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)

      response = http_post_with_retry(uri, request)
      unless response.is_a?(Net::HTTPSuccess)
        raise ProviderError.new("Claude API HTTP #{response.code}: #{response.body.to_s[0, 500]}",
                                provider: provider_name, http_status: response.code)
      end

      result = parse_provider_json(response)
      if result['error']
        raise ProviderError.new("Claude API error: #{result['error']['message']}",
                                provider: provider_name, http_status: response.code)
      end

      if result['stop_reason'] == 'max_tokens'
        @logger.warn("Claude response truncated at max_tokens=#{max_tokens} (stop_reason=max_tokens). " \
                     "Raise llm.claude.max_tokens for complete output.")
      end

      # Pick the text blocks rather than content[0]: models that think (the Claude 5
      # family thinks by default) return thinking blocks ahead of the answer.
      blocks = result['content'] || []
      text = blocks.select { |b| b['type'] == 'text' }.map { |b| b['text'] }.join.strip

      if text.empty?
        raise ProviderError.new("Claude API returned no text content (stop_reason=#{result['stop_reason'].inspect})",
                                provider: provider_name, http_status: response.code)
      end

      text
    end
  end

  class OpenAIClient < Base
    API_URL = 'https://api.openai.com/v1/chat/completions'.freeze
    DEFAULT_MODEL = 'gpt-4o-mini'.freeze

    def initialize(config, logger, language: nil, prompt_addition: nil)
      super
      @api_key = ENV['OPENAI_API_KEY'] || @config['openai_api_key']

      if @api_key.nil? || @api_key.empty?
        raise ConfigError, "OpenAI API key not found. Set OPENAI_API_KEY environment variable or add to config/llm.yml"
      end
    end

    def chat_completion(system:, user:)
      model = @provider_config['model'] || DEFAULT_MODEL
      @logger.info("OpenAI model: #{model}")
      body = {
        model: model,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user }
        ]
      }

      body[:max_tokens] = @provider_config['max_tokens'] unless @provider_config['max_tokens'].nil?
      body[:temperature] = @provider_config['temperature'] unless @provider_config['temperature'].nil?

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@api_key}"
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)

      response = http_post_with_retry(uri, request)
      unless response.is_a?(Net::HTTPSuccess)
        raise ProviderError.new("OpenAI API HTTP #{response.code}: #{response.body.to_s[0, 500]}",
                                provider: provider_name, http_status: response.code)
      end

      result = parse_provider_json(response)
      if result['error']
        raise ProviderError.new("OpenAI API error: #{result.dig('error', 'message')}",
                                provider: provider_name, http_status: response.code)
      end

      if result.dig('choices', 0, 'finish_reason') == 'length'
        @logger.warn("OpenAI response truncated (finish_reason=length). " \
                     "Raise llm.openai.max_tokens for complete output.")
      end

      result.dig('choices', 0, 'message', 'content')
    end
  end

  class AlbertClient < Base
    API_URL = 'https://albert.api.etalab.gouv.fr/v1/chat/completions'.freeze
    DEFAULT_MODEL = 'AgentPublic/llama3-instruct-8b'.freeze

    def initialize(config, logger, language: nil, prompt_addition: nil)
      super
      @api_key = ENV['ALBERT_API_KEY'] || @config['albert_api_key']

      if @api_key.nil? || @api_key.empty?
        raise ConfigError, "Albert API key not found. Set ALBERT_API_KEY environment variable or add albert_api_key to llm.yml"
      end
    end

    def chat_completion(system:, user:)
      model = @provider_config['model'] || DEFAULT_MODEL
      @logger.info("Albert model: #{model}")
      body = {
        model: model,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user }
        ]
      }

      body[:max_tokens] = @provider_config['max_tokens'] unless @provider_config['max_tokens'].nil?
      body[:temperature] = @provider_config['temperature'] unless @provider_config['temperature'].nil?

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri)
      request['Authorization'] = "Bearer #{@api_key}"
      request['content-type'] = 'application/json'
      request.body = JSON.generate(body)

      response = http_post_with_retry(uri, request)

      unless response.is_a?(Net::HTTPSuccess)
        raise ProviderError.new("Albert API HTTP #{response.code}: #{response.body.to_s[0, 500]}",
                                provider: provider_name, http_status: response.code)
      end

      result = parse_provider_json(response)
      if result['error']
        raise ProviderError.new("Albert API error: #{result.dig('error', 'message')}",
                                provider: provider_name, http_status: response.code)
      end

      finish_reason = result.dig('choices', 0, 'finish_reason')
      if finish_reason == 'length'
        @logger.warn("Albert response truncated (finish_reason=length). " \
                     "Raise llm.albert.max_tokens for complete output.")
      end

      content = result.dig('choices', 0, 'message', 'content')
      if content.nil? || content.strip.empty?
        # Previously warned and returned nil, which degraded to a summary-less
        # document with no way to tell an empty answer from a disabled provider.
        raise ProviderError.new(
          "Albert returned empty content (finish_reason=#{finish_reason.inspect}). Full response: #{response.body.to_s[0, 500]}",
          provider: provider_name, http_status: response.code
        )
      end
      content
    end
  end
end
