#!/usr/bin/env ruby
# encoding: UTF-8
#
# albert_whisper.rb — Transcription via Albert AI API.
#
# Strategy:
#   1. POST audio to Albert API → high-quality full text
#   2. Use events.xml (BBB) to derive per-segment timestamps
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
#   albert_api_key: "your-key-here"
#   albert_model:   "openai/whisper-large-v3"  # optional; defaults to "openai/whisper-large-v3"
#   language:       "fr"                       # optional; ISO-639-1 code; omit for auto-detection
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
require 'nokogiri'
require 'logger'
require 'fileutils'

BASE_URL       = 'https://albert.api.etalab.gouv.fr'.freeze
ENDPOINT_PATH  = '/v1/audio/transcriptions'.freeze

# Talking cues closer than this (ms) are merged into a single chunk before
MERGE_GAP_MS        = 1_000
# VAD is only run on clips shorter than this (longer clips are assumed speech).
VAD_MAX_DURATION_MS = 10_000
# Minimum absolute speech duration (ms) required for a clip to pass VAD.
# The adaptive threshold is MIN_SPEECH_MS / clip_duration_ms, floored at the
# configured vad_speech_threshold. Keeps short clips from passing on just a
# few noise frames while avoiding an overly strict threshold on longer clips.
VAD_MIN_SPEECH_MS   = 150
# If Albert returns this many words or fewer, re-run VAD regardless of clip length.
MIN_TRANSCRIPTION_WORDS = 3
VAD_NODE_PATH       = `npm root -g 2>/dev/null`.strip.freeze

# Helpers
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

def text_field(boundary, name, value)
  "--#{boundary}\r\n" \
  "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n" \
  "#{value}\r\n"
end

# Requires: npm install -g node-vad
VAD_INLINE_JS = <<~'JS'
  const VAD = require('node-vad');
  const fs  = require('fs');
  const SAMPLE_RATE = 16000, FRAME_BYTES = 960, WAV_HEADER = 44;
  async function run() {
    const pcm = fs.readFileSync(process.env.VAD_WAV).slice(WAV_HEADER);
    const vad = new VAD(VAD.Mode.VERY_AGGRESSIVE);
    let total = 0, speech = 0;
    for (let i = 0; i + FRAME_BYTES <= pcm.length; i += FRAME_BYTES) {
      const event = await vad.processAudio(pcm.slice(i, i + FRAME_BYTES), SAMPLE_RATE);
      total++;
      if (event === VAD.Event.VOICE) speech++;
    }
    process.stdout.write((total > 0 ? speech / total : 0).toFixed(4) + '\n');
  }
  run().catch(e => { process.stderr.write(e.message + '\n'); process.exit(1); });
JS

def has_speech?(wav_path, enabled:, threshold: 0.05,
                min_speech_ms: VAD_MIN_SPEECH_MS, max_duration_ms: VAD_MAX_DURATION_MS,
                force: false)
  return true unless enabled || force

  duration_ms = audio_duration_ms(wav_path).to_i
  return true if !force && duration_ms > max_duration_ms

  # Adaptive threshold: for short clips a fixed percentage can mean only a few
  # milliseconds of speech (e.g. 5% of 600 ms = 30 ms — humanly impossible).
  # Derive the threshold from the minimum absolute speech duration, floored at
  # the configured base threshold so long clips aren't penalized.
  adaptive = if duration_ms > 0
    [[min_speech_ms.to_f / duration_ms, threshold].max, 0.80].min
  else
    threshold
  end

  env = { 'VAD_WAV' => wav_path }
  env['NODE_PATH'] = VAD_NODE_PATH unless VAD_NODE_PATH.empty?
  out = IO.popen(env, ['node', '-e', VAD_INLINE_JS], &:read)
  status = $?
  unless status.success?
    info "  → VAD: node failed (is node-vad installed globally?), passing through"
    return true
  end

  ratio = out.strip.to_f
  info "  → VAD: #{(ratio * 100).round(1)}% speech frames (threshold: #{(adaptive * 100).round(1)}%)"
  ratio >= adaptive
rescue => e
  info "  → VAD error: #{e.message}, passing through"
  true
end

# Returns audio duration in milliseconds via ffprobe, or nil.
def audio_duration_ms(path)
  out = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{path}" 2>/dev/null`.strip
  out.empty? ? nil : (out.to_f * 1000).round
rescue
  nil
end

# Scans events.xml and returns speaking cues for the given audio file,
def extract_talking_cues(events_doc, audio_file)
  audio_basename  = File.basename(audio_file)
  cues            = []
  inside_track    = false
  audio_start_utc = nil
  user_id         = nil
  cue_start_utc   = nil

  events_doc.xpath('//event').each do |ev|
    case ev['eventname']
    when 'AudioTrackPublishedEvent'
      next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
      inside_track    = true
      audio_start_utc = ev.at_xpath('timestampUTC')&.text.to_i
      user_id         = ev.at_xpath('userId')&.text

    when 'AudioTrackUnpublishedEvent'
      next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
      if cue_start_utc
        cues << { 'from' => cue_start_utc - audio_start_utc,
                  'to'   => ev.at_xpath('timestampUTC')&.text.to_i - audio_start_utc }
        cue_start_utc = nil
      end
      inside_track = false

    when 'ParticipantTalkingEvent'
      next unless inside_track && ev.at_xpath('participant')&.text == user_id
      ts      = ev.at_xpath('timestampUTC')&.text.to_i
      talking = ev.at_xpath('talking')&.text == 'true'
      if talking
        cue_start_utc ||= ts
      elsif cue_start_utc
        cues << { 'from' => cue_start_utc - audio_start_utc, 'to' => ts - audio_start_utc }
        cue_start_utc = nil
      end
    end
  end

  cues
end

# Returns one cue per AudioTrackPublished→Unpublished interval for the given
# audio file. Used as a fallback when no ParticipantTalkingEvents are present.
def extract_floor_cues(events_doc, audio_file)
  audio_basename  = File.basename(audio_file)
  cues            = []
  audio_start_utc = nil
  floor_start_utc = nil

  events_doc.xpath('//event').each do |ev|
    case ev['eventname']
    when 'AudioTrackPublishedEvent'
      next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
      audio_start_utc = ev.at_xpath('timestampUTC')&.text.to_i
      floor_start_utc = audio_start_utc

    when 'AudioTrackUnpublishedEvent'
      next unless File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
      if floor_start_utc && audio_start_utc
        cues << { 'from' => floor_start_utc - audio_start_utc,
                  'to'   => ev.at_xpath('timestampUTC')&.text.to_i - audio_start_utc }
        floor_start_utc = nil
      end
    end
  end

  cues
end

# Merges cues whose inter-cue gap is less than gap_ms,
def merge_nearby_cues(cues, gap_ms)
  return [] if cues.empty?

  merged = [cues.first.dup]
  cues.each_cons(2) do |prev, curr|
    gap = curr['from'] - merged.last['to']
    if gap <= gap_ms
      merged.last['to'] = curr['to']   # extend the current group
    else
      merged << curr.dup
    end
  end
  merged
end

# Cuts a time slice from wav_path with ffmpeg. Returns temp file path or nil.
# from_ms / to_ms are millisecond offsets into the file.
def cut_audio_chunk(wav_path, from_ms, to_ms)
  tmp        = "/tmp/albert_chunk_#{Process.pid}_#{SecureRandom.hex(6)}.wav"
  from_s     = (from_ms / 1000.0).to_s
  duration_s = ((to_ms - from_ms) / 1000.0).to_s
  ok = system(
    'ffmpeg', '-y',
    '-ss', from_s, '-t', duration_s,
    '-i', wav_path,
    '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
    tmp,
    [:out, :err] => '/dev/null'
  )
  ok && File.exist?(tmp) && File.size(tmp) > 0 ? tmp : nil
end

# Posts wav_path to the Albert API. Returns cleaned text or nil.
def call_albert(wav_path, api_key, model, language, http)
  boundary   = "----AlbertBoundary#{SecureRandom.hex(16)}"
  body_parts = []
  body_parts << text_field(boundary, 'model',           model)
  body_parts << text_field(boundary, 'language',        language) if language
  body_parts << text_field(boundary, 'response_format', 'json')
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
    info "Albert API error #{response.code} for #{File.basename(wav_path)}: #{response.body[0, 200]}"
    return nil
  end

  text = clean_repeated_words(JSON.parse(response.body)['text'].to_s.strip)
  text.empty? ? nil : text
rescue => e
  info "Albert call failed for #{File.basename(wav_path)}: #{e.message}"
  nil
end

# Converts audio to 16 kHz mono WAV required by whisper.cpp and Albert.
# Returns [path_to_use, temp_path_to_delete_later] — temp is nil for wav/mp3.
def convert_to_wav(audio_file)
  ext = File.extname(audio_file).downcase.delete('.')
  return [audio_file, nil] if %w[mp3 wav].include?(ext)

  temp_wav = "/tmp/albert_#{Process.pid}_#{SecureRandom.hex(6)}.wav"
  info "Converting #{ext} → WAV: #{File.basename(audio_file)}"
  ok = system(
    'ffmpeg', '-y', '-i', audio_file,
    '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
    temp_wav,
    [:out, :err] => '/dev/null'
  )
  unless ok && File.exist?(temp_wav)
    $stderr.puts "ERROR: ffmpeg conversion failed for #{File.basename(audio_file)}"
    return [nil, nil]
  end
  [temp_wav, temp_wav]
end

# Reads meta_recording-transcription-language
def read_meeting_language(events_xml_path)
  metadata_path = File.join(File.dirname(File.expand_path(events_xml_path)), 'metadata.xml')
  return nil unless File.exist?(metadata_path)

  doc  = Nokogiri::XML(File.read(metadata_path))
  lang = doc.at_xpath('//meta/recording-transcription-language')&.text&.strip
  lang.nil? || lang.empty? ? nil : lang
rescue => e
  info "Could not read metadata.xml: #{e.message}"
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

die "Usage: albert_whisper.rb <audio_file> <output_json_file> <events_xml_file>" \
  if audio_file.nil? || audio_file.strip.empty? ||
     output_json.nil? || output_json.strip.empty? ||
     events_xml.nil? || events_xml.strip.empty?

die "Audio file not found: #{audio_file}" unless File.exist?(audio_file)
die "Events XML not found: #{events_xml}" unless File.exist?(events_xml)

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
$logger = Logger.new(File.join(log_dir, "post_archive-transcribe-albert-#{meeting_id}.log"))
$logger.level = Logger::INFO

# Config
TRANSCRIPTION_YML_PATHS = [
  '/usr/local/bigbluebutton/core/lib/transcription/transcription.yml',
  File.expand_path('transcription.yml', __dir__),
].freeze

config   = {}
yml_path = TRANSCRIPTION_YML_PATHS.find { |p| File.exist?(p) }
if yml_path
  config = YAML.safe_load(File.read(yml_path)) rescue {}
  info "Loaded config from #{yml_path}"
end

albert_cfg = config['albert'] || {}
vad_cfg    = albert_cfg['vad'] || {}

api_key = ENV['ALBERT_API_KEY'].to_s.strip
api_key = albert_cfg['api_key'].to_s.strip if api_key.empty?
die 'No Albert API key found. Set ALBERT_API_KEY or configure albert.api_key in transcription.yml' \
  if api_key.empty?

model = ENV['ALBERT_MODEL'].to_s.strip
model = albert_cfg['model'].to_s.strip if model.empty?
model = 'openai/whisper-large-v3'      if model.empty?

language = ENV['ALBERT_LANGUAGE'].to_s.strip
if language.empty?
  meeting_language = read_meeting_language(events_xml)
  language = meeting_language || config['language'].to_s.strip
end
language = nil if language.empty?

vad_enabled      = vad_cfg['enabled'] == true
vad_threshold    = (vad_cfg['speech_threshold'] || 0.05).to_f
vad_min_speech_ms  = (vad_cfg['min_speech_ms']   || VAD_MIN_SPEECH_MS).to_i
vad_max_duration_ms = (vad_cfg['max_duration_ms'] || VAD_MAX_DURATION_MS).to_i

# Audio conversion (whisper.cpp needs wav; ffmpeg chunk cutting needs wav)
work_file, temp_file = convert_to_wav(audio_file)
die "Audio conversion failed — ffmpeg is required for non-mp3/wav files." if work_file.nil?

info "Audio: #{File.basename(audio_file)} (#{(File.size(work_file) / 1024.0).round(1)} KB)"

info "Model    : #{model}"
lang_source = if !ENV['ALBERT_LANGUAGE'].to_s.strip.empty? then 'env'
               elsif meeting_language                          then 'meta_recording-transcription-language'
               elsif language                                  then 'transcription.yml'
               end
info "Language : #{language || '(auto-detect)'}#{lang_source ? " [#{lang_source}]" : ''}"

# Parse talking cues from events.xml
events_doc = Nokogiri::XML(File.read(events_xml))
raw_cues   = extract_talking_cues(events_doc, audio_file)
cues       = merge_nearby_cues(raw_cues, MERGE_GAP_MS)
info "Talking cues: #{raw_cues.size} raw → #{cues.size} after merging (gap ≤ #{MERGE_GAP_MS}ms)"

if cues.empty?
  floor_cues = extract_floor_cues(events_doc, audio_file)
  if floor_cues.any?
    info "No talking cues — falling back to #{floor_cues.size} floor event interval(s)"
    cues = merge_nearby_cues(floor_cues, MERGE_GAP_MS)
  else
    info "No talking cues and no floor events — treating as silent audio, skipping"
    File.delete(temp_file) if temp_file && File.exist?(temp_file)
    output = { 'transcription' => [] }
    output['language'] = language if language
    File.write(output_json, JSON.pretty_generate(output))
    info "Written 0 segment(s) to #{File.basename(output_json)}"
    exit 0
  end
end

# Shared Albert HTTP connection
uri  = URI("#{BASE_URL}#{ENDPOINT_PATH}")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl      = true
http.open_timeout = 30
http.read_timeout = 600

# Albert API: transcribe each cue
segments = []

http.start do |conn|
  cues.each_with_index do |cue, i|
    from_ms, to_ms = cue['from'], cue['to']
    info "Cue #{i + 1}/#{cues.size}: #{from_ms}ms – #{to_ms}ms"

    chunk = cut_audio_chunk(work_file, from_ms, to_ms)
    unless chunk
      info "  → ffmpeg cut failed, skipping"
      next
    end

    begin
      unless has_speech?(chunk, enabled: vad_enabled, threshold: vad_threshold,
                         min_speech_ms: vad_min_speech_ms, max_duration_ms: vad_max_duration_ms)
        info "  → VAD: insufficient speech, skipping"
        next
      end

      text = call_albert(chunk, api_key, model, language, conn)

      unless text
        info "  → Albert returned empty, skipping"
        next
      end

      word_count = text.split.size
      info "  → #{word_count} word(s)"

      if word_count <= MIN_TRANSCRIPTION_WORDS
        info "  → few words, re-checking with VAD..."
        unless has_speech?(chunk, enabled: true, threshold: vad_threshold,
                           min_speech_ms: vad_min_speech_ms, max_duration_ms: vad_max_duration_ms,
                           force: true)
          info "  → VAD: no speech on re-check, skipping (likely hallucination)"
          next
        end
      end

      segments << { 'offsets' => { 'from' => from_ms, 'to' => to_ms }, 'text' => text }
    ensure
      File.delete(chunk) if File.exist?(chunk)
    end
  end
end

# Cleanup & output
File.delete(temp_file) if temp_file && File.exist?(temp_file)

output = { 'transcription' => segments }
output['language'] = language if language
File.write(output_json, JSON.pretty_generate(output))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"
