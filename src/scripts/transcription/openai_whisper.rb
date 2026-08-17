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
require 'logger'
require 'fileutils'
require_relative 'transcription_utils'

DEFAULT_MODEL = 'whisper-1'.freeze
MAX_BYTES     = 25 * 1024 * 1024  # OpenAI hard limit per request

# Only diarizing transcription models (e.g. gpt-4o-transcribe-diarize) accept and
# act on known_speaker_names[]. whisper-1 and the gpt-4o-*-transcribe models
# currently ignore the field, but sending unknown parameters is fragile — gate it
# on real support so a future stricter API (or a stricter proxy) does not 400.
def diarization_model?(model)
  model.to_s.include?('diarize')
end

# verbose_json returns the detected language as a full lowercase name
# ("english"). Map common names to ISO 639-1 so downstream summarization gets a
# usable language hint. Unknown names return nil rather than a wrong guess.
WHISPER_LANG_TO_ISO = {
  'english' => 'en', 'french' => 'fr', 'spanish' => 'es', 'portuguese' => 'pt',
  'german' => 'de', 'italian' => 'it', 'dutch' => 'nl', 'russian' => 'ru',
  'chinese' => 'zh', 'japanese' => 'ja', 'korean' => 'ko', 'arabic' => 'ar',
  'hindi' => 'hi', 'polish' => 'pl', 'turkish' => 'tr', 'ukrainian' => 'uk',
  'swedish' => 'sv', 'norwegian' => 'no', 'danish' => 'da', 'finnish' => 'fi',
  'greek' => 'el', 'czech' => 'cs', 'romanian' => 'ro', 'hungarian' => 'hu',
  'catalan' => 'ca', 'galician' => 'gl', 'basque' => 'eu'
}.freeze

def whisper_language_to_iso(name)
  return nil if name.nil?
  key = name.to_s.strip.downcase
  return key if key.length == 2   # already an ISO code
  WHISPER_LANG_TO_ISO[key]
end

# Default quality filter parameters
DEFAULT_TEMPERATURE          = 0.0
DEFAULT_NO_SPEECH_THRESHOLD  = 1.0   # 1.0 = disabled; lower to reject high-no-speech-prob segments
DEFAULT_QUALITY_SCORE_THRESHOLD = 0.35

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def die(msg)
  if $logger
    $logger.error(msg)
    $stdout.puts "[ERROR] #{msg}"
  else
    $stderr.puts "ERROR: #{msg}"
  end
  exit 1
end

def info(msg)
  if $logger
    $logger.info(msg)
    $stdout.puts "[INFO ] #{msg}"
  else
    $stderr.puts "INFO : #{msg}"
  end
end

# Non-fatal failures, so an API outage is visible to severity-based alerting.
def log_error(msg)
  if $logger
    $logger.error(msg)
    $stdout.puts "[ERROR] #{msg}"
  else
    $stderr.puts "ERROR: #{msg}"
  end
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
                model: DEFAULT_MODEL,
                temperature: DEFAULT_TEMPERATURE, prompt: nil,
                known_speaker_names: nil,
                no_speech_threshold: DEFAULT_NO_SPEECH_THRESHOLD,
                quality_score_threshold: DEFAULT_QUALITY_SCORE_THRESHOLD)
  empty_result = { segments: [], raw_count: 0, sum_logprob: 0.0, sum_no_speech_prob: 0.0,
                   api_error: false, detected_language: nil }

  file_size = File.size(wav_path)
  if file_size > MAX_BYTES
    info "  → chunk too large (#{(file_size / 1024.0 / 1024).round(1)} MB), skipping"
    return empty_result
  end

  boundary   = "----OpenAIBoundary#{SecureRandom.hex(16)}"
  body_parts = []
  body_parts << text_field(boundary, 'model',           model)
  body_parts << text_field(boundary, 'language',        language) if language
  body_parts << text_field(boundary, 'response_format', 'verbose_json')
  body_parts << text_field(boundary, 'timestamp_granularities[]', 'segment')
  body_parts << text_field(boundary, 'temperature',     temperature.to_s)
  body_parts << text_field(boundary, 'prompt',          prompt) if prompt
  if diarization_model?(model)
    (known_speaker_names || []).each do |name|
      body_parts << text_field(boundary, 'known_speaker_names[]', name)
    end
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
    log_error "PROVIDER_ERROR OpenAI API HTTP #{response.code}: #{response.body.to_s[0, 200]}"
    return empty_result.merge(api_error: true)
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
    sum_logprob: sum_logprob, sum_no_speech_prob: sum_no_speech_prob, api_error: false,
    detected_language: data['language'] }
rescue => e
  info "  → OpenAI call failed: #{e.message}"
  empty_result.merge(api_error: true)
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

# Logger setup — mirrors albert_whisper.rb. Without a file logger this script's
# output only reached the parent transcription log via stdout redirection, so
# its lines carried no timestamp, PID, or severity and API failures could not be
# dated.
# meeting_id is derived from the events.xml path: <recording_dir>/raw/<meeting_id>/events.xml
meeting_id = File.basename(File.dirname(File.expand_path(events_xml)))

BBB_LIB_TRANSCRIPTION_DIR = '/usr/local/bigbluebutton/core/lib/transcription'.freeze
BBB_SCRIPTS_DIR           = '/usr/local/bigbluebutton/core/scripts'.freeze
bbb_props_path            = "#{BBB_SCRIPTS_DIR}/bigbluebutton.yml"

log_dir = if File.expand_path(__dir__) == BBB_LIB_TRANSCRIPTION_DIR && File.exist?(bbb_props_path)
  bbb_props = YAML.safe_load(File.read(bbb_props_path)) || {}
  bbb_props['log_dir'] || '/var/log/bigbluebutton'
else
  dev_cfg_path = File.expand_path('../../config/bigbluebutton.yml', __dir__)
  dev_cfg = File.exist?(dev_cfg_path) ? (YAML.safe_load(File.read(dev_cfg_path)) || {}) : {}
  dev_cfg['log_dir'] || '/tmp'
end

FileUtils.mkdir_p(log_dir)
$stdout.sync = true
$logger = Logger.new(File.join(log_dir, "post_archive-transcribe-openai_whisper-#{meeting_id}.log"))
$logger.level = Logger::INFO

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

model = ENV['OPENAI_MODEL'].to_s.strip
model = openai_cfg['model'].to_s.strip if model.empty?
model = DEFAULT_MODEL if model.empty?

# known_speaker_names only works with diarizing models; drop it otherwise so we
# never send a parameter the model does not support.
if known_speaker_names && !diarization_model?(model)
  info "known_speaker_names provided but model '#{model}' does not support diarization — ignoring"
  known_speaker_names = nil
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
    'model'                   => model,
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
api_error_chunks     = 0
raw_segment_total    = 0
sum_logprob          = 0.0
sum_no_speech_prob   = 0.0
detected_languages   = []
rolling_context      = nil   # tail of the previous chunk's transcript

# Max characters of previous-chunk text to carry forward as Whisper prompt
# context, so terminology and mid-sentence continuations survive chunk splits.
ROLLING_CONTEXT_CHARS = 200

http.start do |conn|
  chunks.each_with_index do |chunk_info, i|
    info "Chunk #{i + 1}/#{chunks.size}: #{chunk_info[:from_ms]}ms – #{chunk_info[:to_ms]}ms"

    # Vocabulary/name prompt first, then the previous chunk's tail last so it sits
    # immediately before the current audio (Whisper treats the prompt as the
    # preceding transcript).
    effective_prompt = [prompt, rolling_context].compact.map(&:strip).reject(&:empty?).join(' ')
    effective_prompt = nil if effective_prompt.empty?

    result_chunk = call_openai(
      chunk_info[:path], api_key, language, conn,
      model:                   model,
      chunk_offset_ms:         chunk_info[:from_ms],
      temperature:             temperature,
      prompt:                  effective_prompt,
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
    api_error_chunks     += 1 if result_chunk[:api_error]
    raw_segment_total    += result_chunk[:raw_count]
    sum_logprob          += result_chunk[:sum_logprob]
    sum_no_speech_prob   += result_chunk[:sum_no_speech_prob]
    detected_languages   << result_chunk[:detected_language] if result_chunk[:detected_language]

    chunk_text = result_chunk[:segments].map { |s| s['text'] }.join(' ').strip
    rolling_context = chunk_text[-ROLLING_CONTEXT_CHARS..] || chunk_text unless chunk_text.empty?
  end
end

# Majority-vote the detected language across chunks and map to ISO 639-1.
# Log the distribution: chunks whose language differs from the majority are a
# useful hallucination signal.
detected_iso = nil
unless detected_languages.empty?
  tally = detected_languages.tally
  majority_name = tally.max_by { |_, c| c }&.first
  detected_iso  = whisper_language_to_iso(majority_name)
  info "Detected language distribution: #{tally.inspect} → majority '#{majority_name}' (ISO: #{detected_iso || 'unknown'})"
end

# ---------------------------------------------------------------------------
# Cleanup & output
# ---------------------------------------------------------------------------

TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])

config_block = {
  'model'                   => model,
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

# Prefer the explicitly configured language; otherwise fall back to the detected one.
effective_language = language || detected_iso

output = { 'transcription' => segments }
output['language'] = effective_language if effective_language
output['metadata'] = { 'config' => config_block, 'quality_metrics' => quality_metrics }

File.write(output_json, JSON.pretty_generate(output))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"

# Fail loud: when a meaningful fraction of chunks failed with API errors (auth,
# rate limit, 5xx), exit non-zero so transcribe_audio.rb retries the whole file
# instead of silently accepting a truncated or empty transcript.
if total_chunks > 0 && api_error_chunks >= (total_chunks / 2.0).ceil
  log_error "ERROR: #{api_error_chunks}/#{total_chunks} chunk(s) failed with API errors — exiting 1 to trigger retry"
  exit 1
end
