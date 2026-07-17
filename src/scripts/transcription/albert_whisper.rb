#!/usr/bin/env ruby
# encoding: UTF-8
#
# albert_whisper.rb — Transcription via Albert AI API.
#
# Strategy:
#   1. Use events.xml (BBB) to derive per-segment timestamps (via transcription_utils.rb)
#   2. POST each audio chunk to Albert API → high-quality text per chunk
#
# Deploy as transcribe.rb in the transcription lib dir:
#   cp src/scripts/transcription/albert_whisper.rb \
#      /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
#   chmod +x /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
#
# Called by transcribe_audio.rb as:
#   transcribe.rb <audio_file> <output_json_file> <events_xml_file>
#
# Configuration (transcription.yml in the same directory, or production path):
#   albert:
#     api_key: "your-key-here"
#     model:   "openai/whisper-large-v3"  # optional
#   language: "fr"                        # optional; ISO-639-1; omit for auto-detection
#   vad:
#     enabled: true                       # optional; requires node-vad
#
# Environment variables override config file:
#   ALBERT_API_KEY
#   ALBERT_MODEL
#   ALBERT_LANGUAGE
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

BASE_URL       = 'https://albert.api.etalab.gouv.fr'.freeze
ENDPOINT_PATH  = '/v1/audio/transcriptions'.freeze

# If Albert returns this many words or fewer, re-run VAD to detect hallucinations.
MIN_TRANSCRIPTION_WORDS = 3

def text_field(boundary, name, value)
  "--#{boundary}\r\n" \
  "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n" \
  "#{value}\r\n"
end

# Posts wav_path to the Albert API. Requests verbose_json so we get segment-level
# timestamps (whisper-large-v3 supports them) instead of one blob per chunk.
# Returns { text:, segments:, language: } or nil. segments may be empty if the
# API returned only a flat transcription.
def call_albert(wav_path, api_key, model, language, http)
  boundary   = "----AlbertBoundary#{SecureRandom.hex(16)}"
  body_parts = []
  body_parts << text_field(boundary, 'model',           model)
  body_parts << text_field(boundary, 'language',        language) if language
  body_parts << text_field(boundary, 'response_format', 'verbose_json')
  body_parts << text_field(boundary, 'temperature',     '0')
  body_parts << "--#{boundary}\r\n" \
                "Content-Disposition: form-data; name=\"file\"; " \
                "filename=\"#{File.basename(wav_path)}\"\r\n" \
                "Content-Type: application/octet-stream\r\n\r\n"
  body_parts << File.binread(wav_path)
  body_parts << "\r\n--#{boundary}--\r\n"

  req = Net::HTTP::Post.new(ENDPOINT_PATH)
  req['Authorization'] = "Bearer #{api_key}"
  req['Content-Type']  = "multipart/form-data; boundary=#{boundary}"
  req.body             = body_parts.map(&:b).join

  response = http.request(req)
  unless response.is_a?(Net::HTTPSuccess)
    $logger.info("Albert API error #{response.code} for #{File.basename(wav_path)}: #{response.body[0, 200]}")
    return nil
  end

  data      = JSON.parse(response.body)
  full_text = clean_repeated_words(data['text'].to_s.strip)
  return nil if full_text.empty?

  { text: full_text, segments: (data['segments'] || []), language: data['language'] }
rescue => e
  $logger.info("Albert call failed for #{File.basename(wav_path)}: #{e.message}")
  nil
end

# Reads meta_recording-transcription-language
def read_meeting_language(events_xml_path)
  metadata_path = File.join(File.dirname(File.expand_path(events_xml_path)), 'metadata.xml')
  return nil unless File.exist?(metadata_path)

  doc  = Nokogiri::XML(File.read(metadata_path))
  lang = doc.at_xpath('//meta/recording-transcription-language')&.text&.strip
  lang.nil? || lang.empty? ? nil : lang
rescue => e
  $logger.info("Could not read metadata.xml: #{e.message}")
  nil
end

# Removes runs of 3+ identical consecutive words from Albert's raw text.
def clean_repeated_words(text)
  words = text.split
  cleaned = []
  i = 0
  while i < words.length
    norm = words[i].downcase.gsub(/[^\w]/, '')
    j = i + 1
    j += 1 while j < words.length && words[j].downcase.gsub(/[^\w]/, '') == norm
    cleaned.concat(words[i, [j - i, 2].min])  # keep at most 2 consecutive identical
    i = j
  end
  cleaned.join(' ')
end

# Arguments
audio_file  = ARGV[0]
output_json = ARGV[1]
events_xml  = ARGV[2]

if audio_file.nil? || audio_file.strip.empty? ||
   output_json.nil? || output_json.strip.empty? ||
   events_xml.nil? || events_xml.strip.empty?
  $stderr.puts "ERROR: Usage: albert_whisper.rb <audio_file> <output_json_file> <events_xml_file>"
  exit 1
end

# Logger setup — mirrors transcribe_audio.rb config loading.
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
$logger = Logger.new(File.join(log_dir, "post_archive-transcribe-albert-#{meeting_id}.log"), 'daily')

unless File.exist?(audio_file)
  $logger.error("Audio file not found: #{audio_file}")
  exit 1
end

unless File.exist?(events_xml)
  $logger.error("Events XML not found: #{events_xml}")
  exit 1
end

# Config

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

# Loads transcription.yml from the first existing path in +yml_paths+ and
def load_transcription_config(yml_paths)
  config   = {}
  yml_path = yml_paths.find { |p| File.exist?(p) }
  if yml_path
    config = YAML.safe_load(File.read(yml_path)) rescue {}
    $logger.info("Loaded config from #{yml_path}")
  end

  override_path = '/etc/bigbluebutton/post-archive-transcription.yml'
  if File.exist?(override_path)
    override = YAML.safe_load(File.read(override_path)) rescue {}
    config = deep_merge_hashes(config, override)
    $logger.info("Applied config override from #{override_path}")
  end

  config
end

TRANSCRIPTION_YML_PATHS = [
  '/usr/local/bigbluebutton/core/lib/transcription/transcription.yml',
  File.expand_path('transcription.yml', __dir__),
].freeze

config = load_transcription_config(TRANSCRIPTION_YML_PATHS)

albert_cfg = config['albert'] || {}
vad_cfg    = config['vad']    || {}

api_key = ENV['ALBERT_API_KEY'].to_s.strip
api_key = albert_cfg['api_key'].to_s.strip if api_key.empty?
if api_key.empty?
  $logger.error('No Albert API key found. Set ALBERT_API_KEY or configure albert.api_key in transcription.yml')
  exit 1
end

model = ENV['ALBERT_MODEL'].to_s.strip
model = albert_cfg['model'].to_s.strip if model.empty?
model = 'openai/whisper-large-v3'      if model.empty?

language = ENV['ALBERT_LANGUAGE'].to_s.strip
if language.empty?
  meeting_language = read_meeting_language(events_xml)
  language = meeting_language || config['language'].to_s.strip
end
language = nil if language.empty?

vad_opts = {
  enabled:         vad_cfg['enabled'] == true,
  threshold:       (vad_cfg['speech_threshold'] || 0.05).to_f,
  min_speech_ms:   (vad_cfg['min_speech_ms']    || TranscriptionUtils::VAD_MIN_SPEECH_MS).to_i,
  max_duration_ms: (vad_cfg['max_duration_ms']  || TranscriptionUtils::VAD_MAX_DURATION_MS).to_i,
}

# Prepare audio chunks (VAD filtering applied inside)
livekit = ENV.fetch('BBB_AUDIO_BACKEND', 'livekit') != 'freeswitch'
result = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml,
                                                 livekit:      livekit,
                                                 merge_gap_ms: TranscriptionUtils::MERGE_GAP_MS,
                                                 vad:          vad_opts)
if result.nil?
  $logger.error("Audio conversion failed — ffmpeg is required for non-mp3/wav files.")
  exit 1
end

$logger.info("Audio: #{File.basename(audio_file)} (#{(File.size(result[:work_file]) / 1024.0).round(1)} KB)")

$logger.info("Model    : #{model}")
lang_source = if !ENV['ALBERT_LANGUAGE'].to_s.strip.empty? then 'env'
               elsif meeting_language                          then 'meta_recording-transcription-language'
               elsif language                                  then 'transcription.yml'
               end
$logger.info("Language : #{language || '(auto-detect)'}#{lang_source ? " [#{lang_source}]" : ''}")

chunks = result[:chunks]

if chunks.empty?
  TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
  output = { 'transcription' => [] }
  output['language'] = language if language
  File.write(output_json, JSON.pretty_generate(output))
  $logger.info("Written 0 segment(s) to #{File.basename(output_json)}")
  exit 0
end

# Shared Albert HTTP connection
uri  = URI("#{BASE_URL}#{ENDPOINT_PATH}")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl      = true
http.open_timeout = 30
http.read_timeout = 600

# Albert API: transcribe each chunk
segments           = []
detected_languages = []

# Attaches the chunk's speaker attribution to a segment hash.
attach_speaker = lambda do |seg, chunk_info|
  if chunk_info[:speaker_ids]
    seg['speaker_ids'] = chunk_info[:speaker_ids]
  elsif chunk_info[:speaker_id]
    seg['speaker_id'] = chunk_info[:speaker_id]
  end
  seg
end

http.start do |conn|
  chunks.each_with_index do |chunk_info, i|
    from_ms = chunk_info[:from_ms]
    to_ms   = chunk_info[:to_ms]
    chunk   = chunk_info[:path]
    $logger.info("Chunk #{i + 1}/#{chunks.size}: #{from_ms}ms – #{to_ms}ms")

    res = call_albert(chunk, api_key, model, language, conn)

    unless res
      $logger.info("  → Albert returned empty, skipping")
      next
    end

    text = res[:text]
    detected_languages << res[:language] if res[:language]
    word_count = text.split.size
    $logger.info("  → #{word_count} word(s)#{res[:segments].any? ? ", #{res[:segments].size} segment(s)" : ''}")

    # Re-check with VAD when Albert returns suspiciously few words — likely a
    # hallucination on a clip that slipped through (e.g. VAD disabled or long clip).
    if word_count <= MIN_TRANSCRIPTION_WORDS
      $logger.info("  → few words, re-checking with VAD...")
      unless TranscriptionUtils.has_speech?(chunk, enabled: true,
                                            threshold: vad_opts[:threshold],
                                            min_speech_ms: vad_opts[:min_speech_ms],
                                            max_duration_ms: vad_opts[:max_duration_ms],
                                            force: true)
        $logger.info("  → VAD: no speech on re-check, skipping (likely hallucination)")
        next
      end
    end

    if res[:segments].any?
      # Per-segment timestamps relative to the chunk start (from_ms). This also
      # corrects the 1s pull-back skew: the API places speech at its real offset
      # within the chunk rather than assuming it starts at from_ms.
      res[:segments].each do |vs|
        seg_text = clean_repeated_words(vs['text'].to_s.strip)
        next if seg_text.empty?
        seg = { 'offsets' => { 'from' => from_ms + (vs['start'].to_f * 1000).round,
                               'to'   => from_ms + (vs['end'].to_f   * 1000).round },
                'text' => seg_text }
        segments << attach_speaker.call(seg, chunk_info)
      end
    else
      # Fallback: no segment timestamps — one segment spanning the chunk.
      seg = { 'offsets' => { 'from' => from_ms, 'to' => to_ms }, 'text' => text }
      segments << attach_speaker.call(seg, chunk_info)
    end
  end
end

# Cleanup & output
TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])

# Prefer configured language; else majority-vote the detected language.
effective_language = language
if effective_language.nil? && !detected_languages.empty?
  effective_language = detected_languages.tally.max_by { |_, c| c }&.first
  $logger.info("Detected language: #{effective_language} (#{detected_languages.tally.inspect})")
end

output = { 'transcription' => segments }
output['language'] = effective_language if effective_language
File.write(output_json, JSON.pretty_generate(output))
$logger.info("Written #{segments.size} segment(s) to #{File.basename(output_json)}")
