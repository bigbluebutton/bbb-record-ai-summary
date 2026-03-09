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
# Config file (same directory as this script):
#   transcription.yml — must contain openai_api_key
#
# Environment variables override config file values:
#   OPENAI_API_KEY  — API key
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

# Resolve API key: env var takes priority, then transcription.yml in the same directory.
TRANSCRIPTION_YML = File.join(__dir__, 'transcription.yml').freeze

config     = {}
# yml_path   = TRANSCRIPTION_YML_PATHS.find { |p| File.exist?(p) }
if File.exist?(TRANSCRIPTION_YML)
  config = YAML.safe_load(File.read(TRANSCRIPTION_YML)) rescue {}
  info "Loaded config from #{TRANSCRIPTION_YML}"
end
openai_cfg = config['openai'] || {}

api_key = ENV['OPENAI_API_KEY'].to_s.strip
api_key = openai_cfg['api_key'].to_s.strip if api_key.empty?

die 'No OpenAI API key found. Set OPENAI_API_KEY or configure openai.api_key in transcription.yml' \
  if api_key.empty?

language = ENV['OPENAI_LANGUAGE'].to_s.strip
language = config['language'].to_s.strip if language.empty?
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
body_parts << text_field(boundary, 'timestamp_granularities[]', 'word')
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

  no_speech_prob    = seg['no_speech_prob'].to_f
  compression_ratio = seg['compression_ratio'].to_f


  quality_score =
    (1 - no_speech_prob) * 0.6 +
    (1.0 / compression_ratio) * 0.4

  next if quality_score < 0.4

  {
    'offsets' => {
      'from' => (seg['start'].to_f * 1000).round,
      'to'   => (seg['end'].to_f   * 1000).round
    },
    'text' => text
  }
end

output = { 'transcription' => segments }
output['language'] = data['language'] if data['language']
File.write(output_json, JSON.pretty_generate(output))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"
