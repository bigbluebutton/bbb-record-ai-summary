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
#   transcribe.rb <audio_file> <output_json_file> <events_xml_file>
#
# Config file (same directory as this script):
#   transcription.yml — must contain openai.api_key
#
# Environment variables override config file values:
#   OPENAI_API_KEY  — API key
#   OPENAI_LANGUAGE — BCP-47 language code (e.g. "pt", "es"); omit for auto-detection
#
# OpenAI Whisper API file size limit: 25 MB per request.
# Audio is split into per-speech chunks via events.xml before sending.
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
require_relative 'transcription_utils'

# Known Whisper hallucination patterns (YouTube outros, generic filler).
# Whisper frequently fabricates these phrases over silence or background noise.
HALLUCINATION_PATTERNS = [
  /thank you for watching/i,
  /don't forget to (like|subscribe)/i,
  /see you in the next (video|episode)/i,
  /please (like|subscribe)/i,
  /thanks for (watching|listening)/i,
  /^\s*(thanks\.?|bye\.?|thank you\.?|yes\.?)\s*$/i,
].freeze

MODEL     = 'whisper-1'.freeze
MAX_BYTES = 25 * 1024 * 1024  # OpenAI hard limit per request

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

# Posts a single WAV chunk to the OpenAI Whisper API.
# Returns an array of segment hashes with timestamps offset by chunk_offset_ms, or [].
def call_openai(wav_path, api_key, language, http, chunk_offset_ms: 0, prompt: nil)
  file_size = File.size(wav_path)
  if file_size > MAX_BYTES
    info "  → chunk too large (#{(file_size / 1024.0 / 1024).round(1)} MB), skipping"
    return []
  end

  boundary   = "----OpenAIBoundary#{SecureRandom.hex(16)}"
  body_parts = []
  body_parts << text_field(boundary, 'model',           MODEL)
  body_parts << text_field(boundary, 'language',        language) if language
  body_parts << text_field(boundary, 'response_format', 'verbose_json')
  body_parts << text_field(boundary, 'timestamp_granularities[]', 'segment')
  body_parts << text_field(boundary, 'temperature',     '0')
  body_parts << text_field(boundary, 'prompt',          prompt) if prompt
  body_parts << "--#{boundary}\r\n" \
                "Content-Disposition: form-data; name=\"file\"; " \
                "filename=\"#{File.basename(wav_path)}\"\r\n" \
                "Content-Type: application/octet-stream\r\n\r\n"
  body_parts << File.binread(wav_path)
  body_parts << "\r\n--#{boundary}--\r\n"

  req = Net::HTTP::Post.new('/v1/audio/transcriptions')
  req['Authorization'] = "Bearer #{api_key}"
  req['Content-Type']  = "multipart/form-data; boundary=#{boundary}"
  req.body             = body_parts.map(&:b).join

  response = http.request(req)
  unless response.is_a?(Net::HTTPSuccess)
    info "  → OpenAI API error #{response.code}: #{response.body[0, 200]}"
    return []
  end

  data = JSON.parse(response.body)

  (data['segments'] || []).filter_map do |seg|
    text = seg['text'].to_s.strip
    next if text.empty?
    next if HALLUCINATION_PATTERNS.any? { |pat| text.match?(pat) }

    no_speech_prob    = seg['no_speech_prob'].to_f
    compression_ratio = seg['compression_ratio'].to_f
    quality_score     = (1 - no_speech_prob) * 0.6 + (1.0 / compression_ratio) * 0.4
    next if quality_score < 0.4

    {
      'offsets' => {
        'from' => chunk_offset_ms + (seg['start'].to_f * 1000).round,
        'to'   => chunk_offset_ms + (seg['end'].to_f   * 1000).round
      },
      'text' => text
    }
  end
rescue => e
  info "  → OpenAI call failed: #{e.message}"
  []
end

# ---------------------------------------------------------------------------
# Arguments & environment
# ---------------------------------------------------------------------------

audio_file  = ARGV[0]
output_json = ARGV[1]
events_xml  = ARGV[2]

die "Usage: openai_whisper.rb <audio_file> <output_json_file> <events_xml_file>" \
  if audio_file.nil? || audio_file.strip.empty? ||
     output_json.nil? || output_json.strip.empty? ||
     events_xml.nil? || events_xml.strip.empty?

die "Audio file not found: #{audio_file}" unless File.exist?(audio_file)
die "Events XML not found: #{events_xml}" unless File.exist?(events_xml)

TRANSCRIPTION_YML = File.join(__dir__, 'transcription.yml').freeze

# Recursively merges +override+ into +base+, combining nested hashes key-by-key
# so that only the keys present in +override+ are changed.
def deep_merge_hashes(base, override)
  base.merge(override) do |_key, base_val, override_val|
    if base_val.is_a?(Hash) && override_val.is_a?(Hash)
      deep_merge_hashes(base_val, override_val)
    else
      override_val
    end
  end
end

# Loads transcription.yml from +yml_path+ and applies an optional operator
def load_transcription_config(yml_path)
  config = {}
  if File.exist?(yml_path)
    config = YAML.safe_load(File.read(yml_path)) rescue {}
    info "Loaded config from #{yml_path}"
  end

  override_path = '/etc/bigbluebutton/post-archive-transcription.yml'
  if File.exist?(override_path)
    override = YAML.safe_load(File.read(override_path)) rescue {}
    config = deep_merge_hashes(config, override)
    info "Applied config override from #{override_path}"
  end

  config
end

config     = load_transcription_config(TRANSCRIPTION_YML)
openai_cfg = config['openai'] || {}
vad_cfg    = config['vad']    || {}

api_key = ENV['OPENAI_API_KEY'].to_s.strip
api_key = openai_cfg['api_key'].to_s.strip if api_key.empty?
die 'No OpenAI API key found. Set OPENAI_API_KEY or configure openai.api_key in transcription.yml' \
  if api_key.empty?

language = ENV['OPENAI_LANGUAGE'].to_s.strip
language = config['language'].to_s.strip if language.empty?
language = nil if language.empty?

vad_opts = {
  enabled:         vad_cfg['enabled'] == true,
  threshold:       (vad_cfg['speech_threshold'] || 0.05).to_f,
  min_speech_ms:   (vad_cfg['min_speech_ms']    || TranscriptionUtils::VAD_MIN_SPEECH_MS).to_i,
  max_duration_ms: (vad_cfg['max_duration_ms']  || TranscriptionUtils::VAD_MAX_DURATION_MS).to_i,
}

# ---------------------------------------------------------------------------
# Extract speaker name from events.xml for this audio track
# ---------------------------------------------------------------------------

speaker_name = nil
if File.exist?(events_xml)
  require 'nokogiri'
  events_doc     = Nokogiri::XML(File.open(events_xml))
  audio_basename = File.basename(audio_file)

  # Find the userId associated with this audio track
  track_user_id = nil
  events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").each do |ev|
    if File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
      track_user_id = ev.at_xpath('userId')&.text
      break
    end
  end

  # Look up the participant name
  if track_user_id
    events_doc.xpath("//event[@eventname='ParticipantJoinEvent']").each do |ev|
      if ev.at_xpath('userId')&.text == track_user_id
        speaker_name = ev.at_xpath('name')&.text
        break
      end
    end
  end
end

speaker_prompt = if speaker_name
  info "Speaker: #{speaker_name}"
  "Meeting participant #{speaker_name} speaking. This is their individual microphone audio from a meeting."
else
  nil
end

# ---------------------------------------------------------------------------
# Prepare audio chunks via events.xml (VAD filtering applied inside)
# ---------------------------------------------------------------------------

result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml, vad: vad_opts)
die "Audio conversion failed — ffmpeg is required for non-mp3/wav files." if result.nil?

info "Audio: #{File.basename(audio_file)} (#{(File.size(result[:work_file]) / 1024.0).round(1)} KB)"

chunks = result[:chunks]

if chunks.empty?
  TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
  File.write(output_json, JSON.pretty_generate({ 'transcription' => [] }))
  info "Written 0 segment(s) to #{File.basename(output_json)}"
  exit 0
end

info "Chunks: #{chunks.size}"

# ---------------------------------------------------------------------------
# HTTP connection (shared across all chunks)
# ---------------------------------------------------------------------------

uri  = URI('https://api.openai.com/v1/audio/transcriptions')
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl      = true
http.open_timeout = 30
http.read_timeout = 600

# ---------------------------------------------------------------------------
# Transcribe each chunk
# ---------------------------------------------------------------------------

segments = []

http.start do |conn|
  chunks.each_with_index do |chunk_info, i|
    info "Chunk #{i + 1}/#{chunks.size}: #{chunk_info[:from_ms]}ms – #{chunk_info[:to_ms]}ms"
    segs = call_openai(chunk_info[:path], api_key, language, conn,
                       chunk_offset_ms: chunk_info[:from_ms],
                       prompt: speaker_prompt)
    info "  → #{segs.size} segment(s)"
    segments.concat(segs)
  end
end

# ---------------------------------------------------------------------------
# Cleanup & output
# ---------------------------------------------------------------------------

TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])

output = { 'transcription' => segments }
File.write(output_json, JSON.pretty_generate(output))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"
