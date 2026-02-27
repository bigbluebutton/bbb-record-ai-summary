#!/usr/bin/env ruby
# encoding: UTF-8
#
# albert_whisper.rb — Two-pass transcription: whisper.cpp for timestamps,
#                     Albert AI API for high-quality text.
#
# Strategy:
#   1. Run whisper.cpp locally → timestamped segments + language detection
#   2. POST audio to Albert API → high-quality full text
#   3. Distribute Albert's words proportionally across whisper's time segments
#   Fallback: if whisper.cpp is unavailable, output a single Albert segment.
#
# Deploy as transcribe.rb in the transcription lib dir:
#   cp src/scripts/transcription/albert_whisper.rb \
#      /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
#   chmod +x /usr/local/bigbluebutton/core/lib/transcription/transcribe.rb
#
# Called by transcribe_audio.rb as:
#   transcribe.rb <audio_file> <output_json_file>
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
# whisper.cpp install paths (set by deploy.sh):
#   Binary : /usr/local/bin/whisper.cpp/build/bin/whisper-cli
#   Model  : /usr/local/bin/whisper.cpp/models/ggml-base.bin
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
require 'open3'

BASE_URL       = 'https://albert.api.etalab.gouv.fr'.freeze
ENDPOINT_PATH  = '/v1/audio/transcriptions'.freeze
WHISPER_BIN    = '/usr/local/bin/whisper.cpp/build/bin/whisper-cli'.freeze
WHISPER_MODEL  = '/usr/local/bin/whisper.cpp/models/ggml-base.bin'.freeze

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

# Returns audio duration in milliseconds via ffprobe, or nil.
def audio_duration_ms(path)
  out = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{path}" 2>/dev/null`.strip
  out.empty? ? nil : (out.to_f * 1000).round
rescue
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

# Returns true if a whisper segment looks like a hallucination over silence.
# duration_ms is the segment length and is used for a speech-density check.
def whisper_hallucination?(text, duration_ms = nil)
  words = text.downcase.scan(/\w+/)
  return true if words.empty?

  # Density check: real speech is rarely below 0.5 words/sec.
  # A single "Aham." over a 6-second silence is 0.17 words/sec → hallucination.
  # We additionally require ≤ 2 unique words to avoid filtering short but unique phrases.
  if duration_ms && duration_ms > 0
    words_per_sec = words.size.to_f / (duration_ms / 1000.0)
    return true if words_per_sec < 0.5 && words.uniq.size <= 2
  end

  return false if words.size < 3

  # Same single token repeated 3+ times consecutively
  return true if words.each_cons(3).any? { |trio| trio.uniq.size == 1 }

  # Very low unique-word ratio for segments with 4+ words
  return true if words.size >= 4 && words.uniq.size.to_f / words.size < 0.4

  false
end

# Runs whisper.cpp on wav_path. Returns { language: "pt", segments: [...] } or nil.
# segments format: [{ "offsets" => { "from" => ms, "to" => ms }, "text" => "..." }, ...]
def run_whisper(wav_path)
  return nil unless File.executable?(WHISPER_BIN) && File.exist?(WHISPER_MODEL)

  prefix = "/tmp/albert_wsp_#{Process.pid}_#{SecureRandom.hex(6)}"
  json_out = "#{prefix}.json"

  info "Running whisper.cpp for timestamps..."
  stdout_err, status = Open3.capture2e(
    WHISPER_BIN,
    '-m', WHISPER_MODEL,
    '-f', wav_path,
    '-l', 'auto',
    '-oj',          # write JSON output file
    '-of', prefix   # whisper appends .json automatically
  )

  unless status.success? && File.exist?(json_out)
    info "whisper.cpp failed — will fall back to single Albert segment"
    return nil
  end

  data = JSON.parse(File.read(json_out))
  File.delete(json_out)

  raw_segments = (data['transcription'] || []).filter_map do |s|
    text = s['text'].to_s.strip
    next if text.empty?
    { 'offsets' => s['offsets'], 'text' => text }
  end

  segments = raw_segments.reject do |s|
    dur = s['offsets']['to'].to_i - s['offsets']['from'].to_i
    whisper_hallucination?(s['text'], dur)
  end
  dropped  = raw_segments.size - segments.size
  info "whisper.cpp: #{segments.size} segment(s) kept, #{dropped} hallucination(s) dropped"

  # Extract detected language from stderr output
  lang_match = stdout_err.match(/auto-detected language:\s+([a-z]{2,3})/i)
  language   = lang_match ? lang_match[1].downcase : nil

  info "whisper.cpp: language: #{language || 'unknown'}"
  { language: language, segments: segments }
rescue => e
  info "whisper.cpp error: #{e.message} — falling back to single Albert segment"
  nil
end

# Removes runs of 3+ identical consecutive words from Albert's raw text.
# "Aham Aham Aham Aham" → ""  ;  "sim sim" → "sim sim"
# This cleans hallucinations that Albert generates over silence before distribution.
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

# Distributes albert_text words proportionally across whisper_segments timings.
# Each segment's ratio of words is proportional to its own whisper word count.
def distribute_text(albert_text, whisper_segments)
  words = albert_text.split
  total_w_words = whisper_segments.sum { |s| s['text'].split.size }
  return whisper_segments.map { |s| s.merge('text' => '') } if total_w_words.zero?

  pos    = 0
  result = whisper_segments.map.with_index do |seg, i|
    word_ratio_for_segment = seg['text'].split.size.to_f / total_w_words
    count = (word_ratio_for_segment * words.size).round
    # Last segment absorbs any rounding remainder
    chunk = (i == whisper_segments.size - 1) ? words[pos..] : words[pos, count]
    pos  += count
    { 'offsets' => seg['offsets'], 'text' => (chunk || []).join(' ') }
  end

  result.reject { |s| s['text'].strip.empty? }
end

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

audio_file  = ARGV[0]
output_json = ARGV[1]

die "Usage: albert_whisper.rb <audio_file> <output_json_file>" \
  if audio_file.nil? || audio_file.strip.empty? ||
     output_json.nil? || output_json.strip.empty?

die "Audio file not found: #{audio_file}" unless File.exist?(audio_file)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

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

api_key = ENV['ALBERT_API_KEY'].to_s.strip
api_key = config['albert_api_key'].to_s.strip if api_key.empty?
die 'No Albert API key found. Set ALBERT_API_KEY or configure albert_api_key in transcription.yml' \
  if api_key.empty?

model = ENV['ALBERT_MODEL'].to_s.strip
model = config['albert_model'].to_s.strip if model.empty?
model = 'openai/whisper-large-v3'         if model.empty?

language = ENV['ALBERT_LANGUAGE'].to_s.strip
language = config['language'].to_s.strip if language.empty?
language = nil if language.empty?

# ---------------------------------------------------------------------------
# Audio conversion (Albert accepts mp3/wav only; whisper.cpp needs wav)
# ---------------------------------------------------------------------------

work_file, temp_file = convert_to_wav(audio_file)
die "Audio conversion failed — ffmpeg is required for non-mp3/wav files." if work_file.nil?

file_size   = File.size(work_file)
duration_ms = audio_duration_ms(work_file) || audio_duration_ms(audio_file)
info "Audio: #{File.basename(audio_file)} (#{(file_size / 1024.0).round(1)} KB)"

# ---------------------------------------------------------------------------
# Pass 1 — whisper.cpp: timestamps + language detection
# ---------------------------------------------------------------------------

whisper_result = run_whisper(work_file)

if language.nil? && whisper_result&.dig(:language)
  language = whisper_result[:language]
  info "Detected language: #{language}"
end

# ---------------------------------------------------------------------------
# Pass 2 — Albert API: high-quality text
# ---------------------------------------------------------------------------

boundary   = "----AlbertBoundary#{SecureRandom.hex(16)}"
body_parts = []
body_parts << text_field(boundary, 'model',           model)
body_parts << text_field(boundary, 'language',        language) if language
body_parts << text_field(boundary, 'response_format', 'json')
body_parts << text_field(boundary, 'temperature',     '0')
body_parts << "--#{boundary}\r\n" \
              "Content-Disposition: form-data; name=\"file\"; " \
              "filename=\"#{File.basename(work_file)}\"\r\n" \
              "Content-Type: application/octet-stream\r\n\r\n"
body_parts << File.binread(work_file)
body_parts << "\r\n--#{boundary}--\r\n"
body = body_parts.map(&:b).join

# Done reading work_file — clean up temp wav
File.delete(temp_file) if temp_file && File.exist?(temp_file)

uri  = URI("#{BASE_URL}#{ENDPOINT_PATH}")
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl      = true
http.open_timeout = 30
http.read_timeout = 600

req = Net::HTTP::Post.new(uri.path)
req['Authorization'] = "Bearer #{api_key}"
req['Content-Type']  = "multipart/form-data; boundary=#{boundary}"
req.body = body

info "Model    : #{model}"
info "Language : #{language || '(auto-detect)'}"
info "Calling Albert API (#{uri.host})..."

begin
  response = http.request(req)
rescue => e
  die "Network error: #{e.message}"
end

unless response.is_a?(Net::HTTPSuccess)
  die "Albert API returned HTTP #{response.code}: #{response.body}"
end

begin
  data = JSON.parse(response.body)
rescue JSON::ParserError => e
  die "Failed to parse API response: #{e.message}"
end

albert_text = data['text'].to_s.strip
die "Albert API returned an empty transcription." if albert_text.empty?

albert_text = clean_repeated_words(albert_text)
info "Albert text: #{albert_text.split.size} word(s) after dedup-cleaning"
die "Albert API returned an empty transcription after cleaning." if albert_text.strip.empty?

# ---------------------------------------------------------------------------
# Merge: distribute Albert text across whisper timestamps
# ---------------------------------------------------------------------------

whisper_segs = whisper_result&.dig(:segments)

segments =
  if whisper_segs && !whisper_segs.empty?
    merged = distribute_text(albert_text, whisper_segs)
    info "Merged Albert text across #{merged.size} whisper segment(s)"
    merged
  else
    info "No whisper segments — outputting single Albert segment"
    [{ 'offsets' => { 'from' => 0, 'to' => duration_ms || 0 }, 'text' => albert_text }]
  end

File.write(output_json, JSON.pretty_generate('transcription' => segments))
info "Written #{segments.size} segment(s) to #{File.basename(output_json)}"
