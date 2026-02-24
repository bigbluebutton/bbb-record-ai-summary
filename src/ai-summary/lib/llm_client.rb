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

    def self.create(logger)
      llm_config_path = get_config_path()

      config = YAML.load_file(llm_config_path)
      provider = config['provider']

      case provider
      when 'claude'
        ClaudeClient.new(config)
      when 'openai'
        OpenAIClient.new(config)
      when 'disabled'
        logger.info("LLM summary is disabled")
        DisabledClient.new(config)
      else
        raise "Unknown LLM provider: #{provider}. Use 'claude', 'openai', or 'disabled'"
      end
    end

    def initialize(config)
      @config = config
      @provider_config = config[@config['provider']] || {}
    end

    def summarize(text)
      raise NotImplementedError, "Subclass must implement summarize method"
    end

    protected

    def system_prompt
      @config['system_prompt'] || "Summarize the following meeting content."
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

    def initialize(config)
      super
      @api_key = ENV['ANTHROPIC_API_KEY'] || @config['anthropic_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "Anthropic API key not found. Set ANTHROPIC_API_KEY environment variable or add to /usr/local/bigbluebutton/core/scripts/ai-summary/llm.yml"
      end
    end

    def summarize(text)
      body = {
        model: @provider_config['model'] || 'claude-3-5-sonnet-20241022',
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

    def initialize(config)
      super
      @api_key = ENV['OPENAI_API_KEY'] || @config['openai_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "OpenAI API key not found. Set OPENAI_API_KEY environment variable or add to config/llm.yml"
      end
    end

    def summarize(text)
      body = {
        model: @provider_config['model'] || 'gpt-4o-mini',
        max_tokens: @provider_config['max_tokens'] || 1024,
        temperature: @provider_config['temperature'] || 0.7,
        messages: [
          { role: 'system', content: system_prompt },
          { role: 'user', content: text }
        ]
      }

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
end
