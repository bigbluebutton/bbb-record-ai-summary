# LLM Client abstraction for multiple providers
require 'yaml'

module LLMClient
  class Base
    attr_reader :config, :provider_config

    def self.create(config_path)
      config = YAML.load_file(config_path)
      provider = config['provider']

      case provider
      when 'claude'
        ClaudeClient.new(config)
      when 'openai'
        OpenAIClient.new(config)
      when 'disabled'
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
    def initialize(config)
      super
      require 'anthropic'

      # Environment variable takes priority
      @api_key = ENV['ANTHROPIC_API_KEY'] || @config['anthropic_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "Anthropic API key not found. Set ANTHROPIC_API_KEY environment variable or add to config/llm.yml"
      end

      @client = Anthropic::Client.new(access_token: @api_key)
    end

    def summarize(text)
      response = @client.messages(
        parameters: {
          model: @provider_config['model'] || 'claude-3-5-sonnet-20241022',
          max_tokens: @provider_config['max_tokens'] || 1024,
          temperature: @provider_config['temperature'] || 0.7,
          system: system_prompt,
          messages: [
            { role: 'user', content: text }
          ]
        }
      )

      # Extract text from response
      response.dig('content', 0, 'text')
    rescue StandardError => e
      raise "Claude API error: #{e.message}"
    end
  end

  class OpenAIClient < Base
    def initialize(config)
      super
      require 'openai'

      # Environment variable takes priority
      @api_key = ENV['OPENAI_API_KEY'] || @config['openai_api_key']

      if @api_key.nil? || @api_key.empty?
        raise "OpenAI API key not found. Set OPENAI_API_KEY environment variable or add to config/llm.yml"
      end

      @client = OpenAI::Client.new(access_token: @api_key)
    end

    def summarize(text)
      response = @client.chat(
        parameters: {
          model: @provider_config['model'] || 'gpt-4o-mini',
          max_tokens: @provider_config['max_tokens'] || 1024,
          temperature: @provider_config['temperature'] || 0.7,
          messages: [
            { role: 'system', content: system_prompt },
            { role: 'user', content: text }
          ]
        }
      )

      # Extract text from response
      response.dig('choices', 0, 'message', 'content')
    rescue StandardError => e
      raise "OpenAI API error: #{e.message}"
    end
  end
end
