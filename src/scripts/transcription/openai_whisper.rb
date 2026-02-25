#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper.rb — Transcribe an audio file using the OpenAI Whisper API (whisper-1).
#
# Deploy as transcribe.rb in the transcription lib dir:
#   cp src/scripts/transcription/openai_whisper.rb \
#      /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
#   chmod +x /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
#
# Called by transcribe_audio.rb as:
#   transcribe.rb <audio_file> <output_json_file>
#
# Required environment variable:
#   OPENAI_API_KEY
#
# Optional environment variables:
#   OPENAI_LANGUAGE — BCP-47 language code (e.g. "pt", "es"); omit for auto-detection
#
# OpenAI Whisper API file size limit: 25 MB.
#
# Output format (as expected by transcribe_audio.rb):
#   {
#     "transcription": [
#       { "offsets": { "from": <ms>, "to": <ms> }, "text": "..." },
#       ...
#     ]
#   }
#

require 'net/http'
require 'uri'
require 'json'
require 'securerandom'
require 'yaml'

MODEL = 'whisper-1'.freeze

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def die(msg)
  $stderr.puts "ERROR: #{msg}"
  exit 1
end

def info(msg)
  $stderr.puts "INFO : #{msg}"
end

def text_field(boundary, name, value)
  "--#{boundary}\r\n" \
  "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n" \
  "#{value}\r\n"
end

# ---------------------------------------------------------------------------
# Arguments & environment
# ---------------------------------------------------------------------------

audio_file  = ARGV[0]
output_json = ARGV[1]

die "Usage: openai_whisper.rb <audio_file> <output_json_file>" \
  if audio_file.nil? || audio_file.strip.empty? ||
     output_json.nil? || output_json.strip.empty?

die "Audio file not found: #{audio_file}" unless File.exist?(audio_file)

# Resolve API key: env var takes priority, then llm.yml (production path first).
LLM_YML_SEARCH_PATHS = [
  '/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml',
  File.expand_path('../../ai-summary/llm.yml', __dir__),  # dev: src/ai-summary/llm.yml
].freeze

api_key = ENV['OPENAI_API_KEY']

if api_key.nil? || api_key.strip.empty?
  llm_yml_path = LLM_YML_SEARCH_PATHS.find { |p| File.exist?(p) }
  if llm_yml_path
    llm_config = YAML.safe_load(File.read(llm_yml_path)) rescue {}
    api_key = llm_config['openai_api_key'].to_s.strip
    info "Using API key from #{llm_yml_path}" unless api_key.empty?
  end
end

die 'No OpenAI API key found. Set OPENAI_API_KEY or configure openai_api_key in llm.yml' \
  if api_key.nil? || api_key.strip.empty?

language = ENV['OPENAI_LANGUAGE'].to_s.strip
language = nil if language.empty?

# ---------------------------------------------------------------------------
# File size guard — OpenAI hard limit is 25 MB
# ---------------------------------------------------------------------------

MAX_BYTES = 25 * 1024 * 1024
file_size = File.size(audio_file)

if file_size > MAX_BYTES
  die "File too large: #{(file_size / 1024.0 / 1024).round(1)} MB " \
      "(OpenAI limit is 25 MB). Use ffmpeg to compress or split the file."
end

info "Transcribing #{File.basename(audio_file)} (#{(file_size / 1024.0).round(1)} KB)..."

# ---------------------------------------------------------------------------
# Build multipart/form-data body
# ---------------------------------------------------------------------------

boundary = "----OpenAIBoundary#{SecureRandom.hex(16)}"

body_parts = []
body_parts << text_field(boundary, 'model',          MODEL)
body_parts << text_field(boundary, 'language',       language) if language
body_parts << text_field(boundary, 'response_format', 'verbose_json')
body_parts << text_field(boundary, 'timestamp_granularities[]', 'segment')
body_parts << "--#{boundary}\r\n" \
              "Content-Disposition: form-data; name=\"file\"; " \
              "filename=\"#{File.basename(audio_file)}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n"
body_parts << File.binread(audio_file)
body_parts << "\r\n--#{boundary}--\r\n"

# Force binary encoding on every part before joining to avoid conflicts
# between the UTF-8 header strings and the raw audio bytes.
body = body_parts.map(&:b).join

# ---------------------------------------------------------------------------
# HTTP request
# ---------------------------------------------------------------------------

uri  = URI('https://api.openai.com/v1/audio/transcriptions')
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl      = true
http.open_timeout = 30
http.read_timeout = 600  # 10 min; long recordings take time

req = Net::HTTP::Post.new(uri.path)
req['Authorization'] = "Bearer #{api_key}"
req['Content-Type']  = "multipart/form-data; boundary=#{boundary}"
req.body = body

info "Calling OpenAI API..."

begin
  response = http.request(req)
rescue => e
  die "Network error: #{e.message}"
end

unless response.is_a?(Net::HTTPSuccess)
  die "OpenAI API returned HTTP #{response.code}: #{response.body}"
end

# ---------------------------------------------------------------------------
# Parse response → project segment format
# Whisper timestamps are in seconds (Float); project uses milliseconds (Integer).
# ---------------------------------------------------------------------------

begin
  data = JSON.parse(response.body)
rescue JSON::ParserError => e
  die "Failed to parse API response: #{e.message}"
end

segments = (data['segments'] || []).filter_map do |seg|
  text = seg['text'].to_s.strip
  next if text.empty?

  {
    'offsets' => {
      'from' => (seg['start'].to_f * 1000).round,
      'to'   => (seg['end'].to_f   * 1000).round
    },
    'text' => text
  }
end

File.write(output_json, JSON.pretty_generate('transcription' => segments))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"
