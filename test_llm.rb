#!/usr/bin/env ruby
# Test script to verify LLM configuration and API key

require_relative 'notes/lib/llm_client'
require 'yaml'

puts "╔══════════════════════════════════════════════════════════╗"
puts "║  LLM Configuration Test                                  ║"
puts "╚══════════════════════════════════════════════════════════╝"
puts ""

# Load configuration
config_path = File.join(__dir__, 'config', 'llm.yml')

unless File.exist?(config_path)
  puts "❌ Error: Configuration file not found at #{config_path}"
  exit 1
end

config = YAML.load_file(config_path)
provider = config['provider']

puts "Configuration:"
puts "  Provider: #{provider}"

case provider
when 'claude'
  api_key = ENV['ANTHROPIC_API_KEY'] || config['anthropic_api_key']
  key_source = ENV['ANTHROPIC_API_KEY'] ? 'environment variable' : 'config file'
  model = config.dig('claude', 'model') || 'claude-3-5-sonnet-20241022'
  puts "  Model: #{model}"
  puts "  API Key Source: #{key_source}"
  puts "  API Key: #{api_key[0..10]}...#{api_key[-4..-1]}" if api_key && !api_key.empty?
when 'openai'
  api_key = ENV['OPENAI_API_KEY'] || config['openai_api_key']
  key_source = ENV['OPENAI_API_KEY'] ? 'environment variable' : 'config file'
  model = config.dig('openai', 'model') || 'gpt-4o-mini'
  puts "  Model: #{model}"
  puts "  API Key Source: #{key_source}"
  puts "  API Key: #{api_key[0..10]}...#{api_key[-4..-1]}" if api_key && !api_key.empty?
when 'disabled'
  puts "  ⚠️  LLM summarization is disabled"
  puts ""
  puts "To enable, edit config/llm.yml and set provider to 'claude' or 'openai'"
  exit 0
else
  puts "❌ Error: Unknown provider '#{provider}'"
  exit 1
end

puts ""
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts "Testing API Connection..."
puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
puts ""

begin
  # Create LLM client
  puts "1. Initializing #{provider} client..."
  client = LLMClient::Base.create(config_path)
  puts "   ✓ Client initialized successfully"
  puts ""

  # Test with a simple prompt
  test_prompt = "Please respond with exactly these words: 'API test successful'"

  puts "2. Sending test request..."
  puts "   Prompt: \"#{test_prompt}\""
  puts ""

  response = client.summarize(test_prompt)

  if response.nil? || response.empty?
    puts "❌ Error: Received empty response from API"
    exit 1
  end

  puts "3. Response received:"
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts response
  puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  puts ""
  puts "✅ Success! #{provider.capitalize} API is working correctly"
  puts ""
  puts "Response length: #{response.length} characters"

rescue StandardError => e
  puts ""
  puts "❌ Error: #{e.message}"
  puts ""
  puts "Troubleshooting:"

  case provider
  when 'claude'
    puts "  • Verify your Anthropic API key is correct"
    puts "  • Check that you have API credits available"
    puts "  • Visit https://console.anthropic.com/ to verify your account"
  when 'openai'
    puts "  • Verify your OpenAI API key is correct"
    puts "  • Check that you have API credits available"
    puts "  • Visit https://platform.openai.com/api-keys to verify your key"
  end

  puts "  • Ensure you have internet connectivity"
  puts ""
  exit 1
end
