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
#   OPENAI_API_KEY                  — API key
#   OPENAI_LANGUAGE                 — BCP-47 language code (e.g. "pt", "es"); omit for auto-detection
#   WHISPER_TEMPERATURE             — sampling temperature (default 0.0)
#   WHISPER_PROMPT                  — prompt string sent to the Whisper API (optional)
#   WHISPER_NO_SPEECH_THRESHOLD     — reject segments with no_speech_prob above this (default: disabled)
#   WHISPER_QUALITY_SCORE_THRESHOLD — composite quality score minimum (default 0.4)
#   WHISPER_KNOWN_SPEAKER_NAMES     — comma-separated list of known speaker names for diarization
#                                     (e.g. "Alice,Bob,Carol"); maps to known_speaker_names[] in the API
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

MODEL     = 'whisper-1'.freeze
MAX_BYTES = 25 * 1024 * 1024  # OpenAI hard limit per request

# Default quality filter parameters
DEFAULT_TEMPERATURE          = 0.0
DEFAULT_NO_SPEECH_THRESHOLD  = 1.0   # 1.0 = disabled; lower to reject high-no-speech-prob segments
DEFAULT_QUALITY_SCORE_THRESHOLD = 0.35

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
#
# Returns a hash:
#   {
#     segments:           Array,  # accepted segment hashes
#     raw_count:          Integer, # total segments returned by Whisper (before filtering)
#     sum_logprob:        Float,   # sum of avg_logprob across all raw segments
#     sum_no_speech_prob: Float    # sum of no_speech_prob across all raw segments
#   }
def call_openai(wav_path, api_key, language, http, chunk_offset_ms: 0,
                temperature: DEFAULT_TEMPERATURE, prompt: nil,
                known_speaker_names: nil,
                no_speech_threshold: DEFAULT_NO_SPEECH_THRESHOLD,
                quality_score_threshold: DEFAULT_QUALITY_SCORE_THRESHOLD)
  empty_result = { segments: [], raw_count: 0, sum_logprob: 0.0, sum_no_speech_prob: 0.0 }

  file_size = File.size(wav_path)
  if file_size > MAX_BYTES
    info "  → chunk too large (#{(file_size / 1024.0 / 1024).round(1)} MB), skipping"
    return empty_result
  end

  boundary   = "----OpenAIBoundary#{SecureRandom.hex(16)}"
  body_parts = []
  body_parts << text_field(boundary, 'model',           MODEL)
  body_parts << text_field(boundary, 'language',        language) if language
  body_parts << text_field(boundary, 'response_format', 'verbose_json')
  body_parts << text_field(boundary, 'timestamp_granularities[]', 'segment')
  body_parts << text_field(boundary, 'temperature',     temperature.to_s)
  body_parts << text_field(boundary, 'prompt',          prompt) if prompt
  (known_speaker_names || []).each do |name|
    body_parts << text_field(boundary, 'known_speaker_names[]', name)
  end
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
    return empty_result
  end

  data        = JSON.parse(response.body)
  raw_segs    = data['segments'] || []
  raw_count   = raw_segs.size
  sum_logprob         = raw_segs.sum { |s| s['avg_logprob'].to_f }
  sum_no_speech_prob  = raw_segs.sum { |s| s['no_speech_prob'].to_f }

  segments = raw_segs.filter_map do |seg|
    text = seg['text'].to_s.strip
    next if text.empty?

    no_speech_prob    = seg['no_speech_prob'].to_f
    compression_ratio = seg['compression_ratio'].to_f

    next if no_speech_prob > no_speech_threshold

    quality_score = (1 - no_speech_prob) * 0.6 + (1.0 / compression_ratio) * 0.4
    next if quality_score < quality_score_threshold

    {
      'offsets' => {
        'from' => chunk_offset_ms + (seg['start'].to_f * 1000).round,
        'to'   => chunk_offset_ms + (seg['end'].to_f   * 1000).round
      },
      'text' => text
    }
  end

  { segments: segments, raw_count: raw_count,
    sum_logprob: sum_logprob, sum_no_speech_prob: sum_no_speech_prob }
rescue => e
  info "  → OpenAI call failed: #{e.message}"
  empty_result
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

temperature     = (ENV['WHISPER_TEMPERATURE']            || openai_cfg['temperature']             || DEFAULT_TEMPERATURE).to_f
no_speech_threshold = (ENV['WHISPER_NO_SPEECH_THRESHOLD'] || openai_cfg['no_speech_threshold']    || DEFAULT_NO_SPEECH_THRESHOLD).to_f
quality_threshold   = (ENV['WHISPER_QUALITY_SCORE_THRESHOLD'] || openai_cfg['quality_score_threshold'] || DEFAULT_QUALITY_SCORE_THRESHOLD).to_f

prompt = ENV['WHISPER_PROMPT'].to_s.strip
prompt = openai_cfg['prompt'].to_s.strip if prompt.empty?
prompt = nil if prompt.empty?

known_speaker_names_raw = ENV['WHISPER_KNOWN_SPEAKER_NAMES'].to_s.strip
known_speaker_names = if known_speaker_names_raw.empty?
                        nil
                      else
                        known_speaker_names_raw.split(',').map(&:strip).reject(&:empty?).then { |a| a.empty? ? nil : a }
                      end

vad_opts = {
  enabled:         vad_cfg['enabled'] == true,
  threshold:       (vad_cfg['speech_threshold'] || 0.05).to_f,
  min_speech_ms:   (vad_cfg['min_speech_ms']    || TranscriptionUtils::VAD_MIN_SPEECH_MS).to_i,
  max_duration_ms: (vad_cfg['max_duration_ms']  || TranscriptionUtils::VAD_MAX_DURATION_MS).to_i,
}

# ---------------------------------------------------------------------------
# Prepare audio chunks via events.xml (VAD filtering applied inside)
# ---------------------------------------------------------------------------

livekit = ENV.fetch('BBB_AUDIO_BACKEND', 'livekit') != 'freeswitch'
result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml, livekit: livekit, vad: vad_opts)
die "Audio conversion failed — ffmpeg is required for non-mp3/wav files." if result.nil?

info "Audio: #{File.basename(audio_file)} (#{(File.size(result[:work_file]) / 1024.0).round(1)} KB)"

chunks = result[:chunks]

if chunks.empty?
  TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
  empty_config = {
    'model'                   => MODEL,
    'language'                => language,
    'temperature'             => temperature,
    'quality_score_threshold' => quality_threshold
  }
  empty_config['no_speech_threshold'] = no_speech_threshold if no_speech_threshold != DEFAULT_NO_SPEECH_THRESHOLD
  empty_config['prompt'] = prompt if prompt
  empty_config['known_speaker_names'] = known_speaker_names if known_speaker_names
  empty_output = { 'transcription' => [] }
  empty_output['language'] = language if language
  empty_output['metadata'] = {
    'config'          => empty_config,
    'quality_metrics' => {
      'total_chunks' => 0, 'accepted_chunks' => 0, 'rejected_chunks' => 0,
      'total_words' => 0, 'avg_logprob' => nil, 'avg_no_speech_prob' => nil,
      'coverage_ratio' => nil,
      'silence_hallucination_count' => 0, 'repetition_score' => 0.0, 'known_phrase_hits' => []
    }
  }
  File.write(output_json, JSON.pretty_generate(empty_output))
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

segments             = []
total_chunks         = chunks.size
accepted_chunk_count = 0
raw_segment_total    = 0
sum_logprob          = 0.0
sum_no_speech_prob   = 0.0

http.start do |conn|
  chunks.each_with_index do |chunk_info, i|
    info "Chunk #{i + 1}/#{chunks.size}: #{chunk_info[:from_ms]}ms – #{chunk_info[:to_ms]}ms"
    result_chunk = call_openai(
      chunk_info[:path], api_key, language, conn,
      chunk_offset_ms:         chunk_info[:from_ms],
      temperature:             temperature,
      prompt:                  prompt,
      known_speaker_names:     known_speaker_names,
      no_speech_threshold:     no_speech_threshold,
      quality_score_threshold: quality_threshold
    )
    info "  → #{result_chunk[:segments].size} segment(s) (#{result_chunk[:raw_count]} raw)"
    if chunk_info[:speaker_ids]
      result_chunk[:segments].each { |s| s['speaker_ids'] = chunk_info[:speaker_ids] }
    elsif chunk_info[:speaker_id]
      result_chunk[:segments].each { |s| s['speaker_id'] = chunk_info[:speaker_id] }
    end
    segments.concat(result_chunk[:segments])
    accepted_chunk_count += 1 if result_chunk[:segments].any?
    raw_segment_total    += result_chunk[:raw_count]
    sum_logprob          += result_chunk[:sum_logprob]
    sum_no_speech_prob   += result_chunk[:sum_no_speech_prob]
  end
end

# ---------------------------------------------------------------------------
# Cleanup & output
# ---------------------------------------------------------------------------

TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])

config_block = {
  'model'                   => MODEL,
  'language'                => language,
  'temperature'             => temperature,
  'quality_score_threshold' => quality_threshold
}
config_block['no_speech_threshold'] = no_speech_threshold if no_speech_threshold != DEFAULT_NO_SPEECH_THRESHOLD
config_block['prompt'] = prompt if prompt
config_block['known_speaker_names'] = known_speaker_names if known_speaker_names

avg_logprob        = raw_segment_total > 0 ? (sum_logprob        / raw_segment_total).round(4) : nil
avg_no_speech_prob = raw_segment_total > 0 ? (sum_no_speech_prob / raw_segment_total).round(4) : nil
total_words        = segments.sum { |s| s['text'].split.size }

quality_metrics = {
  'total_chunks'                => total_chunks,
  'accepted_chunks'             => accepted_chunk_count,
  'rejected_chunks'             => total_chunks - accepted_chunk_count,
  'total_words'                 => total_words,
  'avg_logprob'                 => avg_logprob,
  'avg_no_speech_prob'          => avg_no_speech_prob,
  'coverage_ratio'              => total_chunks > 0 ? (accepted_chunk_count.to_f / total_chunks).round(4) : nil,
  # Phase 3 & 4 — computed by transcription_utils.rb in a future phase
  'silence_hallucination_count' => 0,
  'repetition_score'            => 0.0,
  'known_phrase_hits'           => []
}

output = { 'transcription' => segments }
output['language'] = language if language
output['metadata'] = { 'config' => config_block, 'quality_metrics' => quality_metrics }

File.write(output_json, JSON.pretty_generate(output))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"
