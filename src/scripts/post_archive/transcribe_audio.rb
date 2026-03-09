# encoding: UTF-8
#
# Post-archive script: transcribe_audio.rb
#
# Transcribes all audio tracks found in a raw BBB recording and merges them
# into a single output file:
#   recording/raw/<meeting_id>/transcription/transcription.json
#
# Each track is transcribed into a temporary JSON file which is deleted once
# all tracks have been merged.
#
# Output format (transcription.json):
#   {
#     "meeting_id": "<id>",
#     "generated_at": "<ISO8601>",
#     "tracks": [
#       {
#         "file": "<audio_basename>",
#         "segments": [ { "offsets": { "from": <ms>, "to": <ms> }, "text": "..." }, ... ]
#       },
#       ...
#     ]
#   }
#
# Transcription back-end (in order of preference):
#   1. Provider Ruby script — place a file named "transcribe.rb" in:
#        /usr/local/bigbluebutton/core/lib/transcription/   (production)
#        src/scripts/transcription/                          (development)
#      It will be called as:
#        transcribe.rb <audio_file> <output_json_file>
#      Use deploy_transcription.sh to install the desired provider:
#        ./deploy_transcription.sh openai_whisper
#      Output must be a valid JSON file with at minimum a "transcription" array
#      of segment objects: { "offsets": { "from": <ms>, "to": <ms> }, "text": "..." }
#
#   2. whisper.cpp (built-in fallback) — the binary is located by scanning
#      several well-known paths.  The model used is the first ggml-*.bin file
#      found in the models/ directory next to the binary.
#
# BBB pipeline usage:
#   cd /usr/local/bigbluebutton/core && bundle exec ruby scripts/post_archive/transcribe_audio.rb -m <meeting_id>
#

require '/usr/local/bigbluebutton/core/lib/recordandplayback'
require 'optimist'
require 'yaml'
require 'json'
require 'fileutils'
require 'logger'

# Helpers
def log(logger, level, msg)
  logger.send(level, msg)
  prefix = level == :error ? 'ERROR' : level == :warn ? 'WARN ' : 'INFO '
  $stdout.puts "[#{prefix}] #{msg}"
end

# Backend: whisper.cpp (built-in fallback)
class WhisperBackend
  SEARCH_PATHS = [
    # Standard deploy location (set by deploy.sh)
    '/usr/local/bin/whisper.cpp/build/bin/whisper-cli',
    '/usr/local/bin/whisper.cpp/main',
    # Deployed alongside this script
    File.join(File.expand_path(__dir__), 'whisper.cpp', 'build', 'bin', 'whisper-cli'),
    File.join(File.expand_path(__dir__), 'whisper.cpp', 'main'),
    # Legacy BBB location
    '/usr/local/bigbluebutton/core/whisper.cpp/build/bin/whisper-cli',
    '/usr/local/bigbluebutton/core/whisper.cpp/main',
    # System binary
    '/usr/local/bin/whisper-cli',
    '/usr/bin/whisper-cli',
  ].freeze

  MODEL_SEARCH_DIRS = [
    '/usr/local/bin/whisper.cpp/models',
    File.join(File.expand_path(__dir__), 'whisper.cpp', 'models'),
    '/usr/local/bigbluebutton/core/whisper.cpp/models',
    '/usr/local/share/whisper/models',
    '/usr/share/whisper/models',
  ].freeze

  def initialize(logger)
    @logger = logger
    @binary = find_binary
    @model  = find_model
  end

  def available?
    !@binary.nil? && !@model.nil?
  end

  # Logs what was found (or what's missing) so the caller can report errors.
  def report_status
    if @binary.nil?
      log(@logger, :error, "whisper.cpp binary not found. Searched: #{SEARCH_PATHS.join(', ')}")
      log(@logger, :error, "Install whisper.cpp or place a transcribe.rb in a transcription search dir.")
    elsif @model.nil?
      log(@logger, :error, "No whisper model found. Searched dirs: #{MODEL_SEARCH_DIRS.join(', ')}")
    else
      log(@logger, :info, "Binary : #{@binary}")
      log(@logger, :info, "Model  : #{@model}")
    end
  end

  def transcribe(audio_file, output_json, _events_xml = nil)
    wav_path, temp_wav = convert_to_wav(audio_file)
    return false if wav_path.nil?

    output_prefix = output_json.delete_suffix('.json')

    log(@logger, :info, "Running whisper-cli: #{File.basename(audio_file)}")
    ok = system(
      @binary,
      '-m', @model,
      '-f', wav_path,
      '-l', 'auto',
      '-oj',                 # segment-level JSON
      '-of', output_prefix,  # whisper appends .json automatically
      [:out, :err] => '/dev/null'
    )

    # whisper-cli writes <prefix>.json
    whisper_out = "#{output_prefix}.json"

    if ok && File.exist?(whisper_out)
      FileUtils.mv(whisper_out, output_json) unless whisper_out == output_json
      log(@logger, :info, "  -> #{File.basename(output_json)}")
      result = true
    else
      log(@logger, :error, "whisper-cli failed for #{File.basename(audio_file)}")
      result = false
    end

    File.delete(temp_wav) if temp_wav && File.exist?(temp_wav)
    result
  end

  private

  def find_binary
    SEARCH_PATHS.find { |p| File.executable?(p) }
  end

  def find_model
    MODEL_SEARCH_DIRS.each do |dir|
      next unless Dir.exist?(dir)
      # Prefer base.en, then the smallest available ggml model
      model = Dir.glob("#{dir}/ggml-base.en.bin").first ||
              Dir.glob("#{dir}/ggml-*.bin").min_by { |f| File.size(f) }
      if model
        log(@logger, :info, "Using whisper model: #{model}")
        return model
      end
    end
    nil
  end

  # Convert any audio format to 16 kHz mono WAV required by whisper.cpp.
  # Returns [path_to_use, path_to_delete_after] — path_to_delete is nil for WAV inputs.
  def convert_to_wav(audio_file)
    ext = File.extname(audio_file).downcase.delete('.')
    return [audio_file, nil] if ext == 'wav'

    basename = File.basename(audio_file, '.*')
    temp_wav = "/tmp/post_archive_#{Process.pid}_#{basename}.wav"

    log(@logger, :info, "Converting #{ext} -> WAV: #{File.basename(audio_file)}")
    ok = system(
      'ffmpeg', '-y', '-i', audio_file,
      '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
      temp_wav,
      [:out, :err] => '/dev/null'
    )

    unless ok && File.exist?(temp_wav)
      log(@logger, :error, "ffmpeg conversion failed for #{File.basename(audio_file)}")
      return [nil, nil]
    end

    [temp_wav, temp_wav]
  end
end

# Backend: custom transcribe.rb script
class CustomScriptBackend
  SEARCH_DIRS = [
    '/usr/local/bigbluebutton/core/lib/transcription',
    File.expand_path('../../transcription', __dir__),  # dev: src/scripts/transcription/
  ].freeze

  def initialize(logger)
    @logger = logger
    @script = find_script
  end

  def available?
    !@script.nil?
  end

  def report_status
    log(@logger, :info, "Back-end: #{@script}")
  end

  def transcribe(audio_file, output_json, events_xml)
    log(@logger, :info, "Running #{File.basename(@script)}: #{File.basename(audio_file)}")
    ok = system(@script, audio_file, output_json, events_xml)

    if ok && File.exist?(output_json)
      log(@logger, :info, "  -> #{File.basename(output_json)}")
      true
    else
      log(@logger, :error, "Custom script failed for #{File.basename(audio_file)} (exit: #{$?.exitstatus})")
      false
    end
  end

  private

  def find_script
    SEARCH_DIRS
      .map  { |dir| File.join(dir, 'transcribe.rb') }
      .find { |p|   File.executable?(p) }
  end
end

# CLI
opts = Optimist::options do
  opt :meeting_id, 'Meeting id', type: String
end

meeting_id = opts[:meeting_id]
Optimist::die :meeting_id, 'is required' if meeting_id.nil? || meeting_id.strip.empty?

BBB_SCRIPTS_DIR = '/usr/local/bigbluebutton/core/scripts'.freeze
bbb_props_path  = "#{BBB_SCRIPTS_DIR}/bigbluebutton.yml"

if File.expand_path(__dir__) == "#{BBB_SCRIPTS_DIR}/post_archive" && File.exist?(bbb_props_path)
  bbb_props     = YAML.safe_load(File.read(bbb_props_path))
  log_dir       = bbb_props['log_dir'] || '/var/log/bigbluebutton'
  recording_dir = bbb_props['recording_dir'] || '/var/bigbluebutton/recording'
else
  # Dev environment — read from project config (two levels up from src/post_archive/)
  dev_config    = YAML.safe_load(File.read(File.expand_path('../../config/bigbluebutton.yml', __dir__)))
  log_dir       = dev_config['log_dir']
  recording_dir = dev_config['recording_dir']
end

FileUtils.mkdir_p(log_dir) if log_dir
log_path = "#{log_dir}/post_archive-transcribe-#{meeting_id}.log"

$stdout.sync = true
logger = Logger.new(log_path)
logger.level = Logger::INFO
BigBlueButton.logger = logger

log(logger, :info, "Meeting ID : #{meeting_id}")

# Paths + audio discovery
raw_dir           = "#{recording_dir}/raw/#{meeting_id}"
audio_dir         = "#{raw_dir}/audio"
transcription_dir = "#{raw_dir}/transcription"

unless Dir.exist?(raw_dir)
  log(logger, :error, "Raw recording directory not found: #{raw_dir}")
  exit 1
end

FileUtils.mkdir_p(transcription_dir)
log(logger, :info, "Transcription output: #{transcription_dir}")

AUDIO_EXTENSIONS = %w[webm opus mp3 wav ogg m4a flac].freeze

audio_files = AUDIO_EXTENSIONS.flat_map { |ext| Dir.glob("#{audio_dir}/*.#{ext}") }.sort

if audio_files.empty?
  log(logger, :warn, "No audio files found in #{audio_dir} — nothing to transcribe.")
  exit 0
end

log(logger, :info, "Found #{audio_files.size} audio file(s): #{audio_files.map { |f| File.basename(f) }.join(', ')}")

# Select transcription back-end (custom script takes priority)
backend = CustomScriptBackend.new(logger)

unless backend.available?
  backend = WhisperBackend.new(logger)

  unless backend.available?
    backend.report_status
    log(logger, :warn, "No transcription backend available — skipping transcription.")
    exit 0
  end

  log(logger, :info, "Back-end: whisper.cpp (built-in fallback)")
end

backend.report_status

# Skip if output already exists
OUTPUT_JSON = File.join(transcription_dir, 'transcription.json').freeze

if File.exist?(OUTPUT_JSON)
  log(logger, :info, "transcription.json already exists — skipping (delete it to re-run)")
  exit 0
end

# Transcribe each audio file, then merge into transcription.json
track_results = []   # { file:, segments:, ok: }
temp_files    = []   # paths to clean up regardless of outcome

events_xml = File.join(raw_dir, 'events.xml')

audio_files.each do |audio_file|
  basename  = File.basename(audio_file)
  temp_json = File.join(transcription_dir, ".tmp_#{basename}.json")
  temp_files << temp_json

  success = false
  max_attempts = 5
  wait = 5
  max_attempts.times do |attempt|
    File.delete(temp_json) if File.exist?(temp_json)
    success = backend.transcribe(audio_file, temp_json, events_xml)
    break if success
    if attempt + 1 < max_attempts
      log(logger, :warn, "  Attempt #{attempt + 1}/#{max_attempts} failed for #{basename}, retrying in #{wait}s...")
      sleep(wait)
      wait *= 2
    end
  end

  unless success
    track_results << { file: basename, segments: [], ok: false }
    next
  end

  begin
    raw      = JSON.parse(File.read(temp_json))
    segments = (raw['transcription'] || []).map do |s|
      { 'offsets' => s['offsets'], 'text' => s['text'].to_s.strip }
    end.reject { |s| s['text'].empty? }

    track_results << { file: basename, segments: segments, ok: true, language: raw['language'] }
    log(logger, :info, "  #{basename}: #{segments.size} segment(s)")
  rescue JSON::ParserError => e
    log(logger, :error, "Failed to parse temp JSON for #{basename}: #{e.message}")
    track_results << { file: basename, segments: [], ok: false }
  end
end

detected_language = track_results.filter_map { |r| r[:language] }.first

merged = {
  'meeting_id'   => meeting_id,
  'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
  'tracks'       => track_results.map { |r| { 'file' => r[:file], 'segments' => r[:segments] } }
}
merged['language'] = detected_language if detected_language

File.write(OUTPUT_JSON, JSON.pretty_generate(merged))
log(logger, :info, "Written: #{OUTPUT_JSON}")

temp_files.each { |f| File.delete(f) if File.exist?(f) }

# Summary
ok_count       = track_results.count { |r|  r[:ok] }
failed_count   = track_results.count { |r| !r[:ok] }
total_segments = track_results.sum   { |r|  r[:segments].size }

log(logger, :info, "=== Transcription complete ===")
log(logger, :info, "  Tracks succeeded : #{ok_count} / #{audio_files.size}")
log(logger, :info, "  Total segments   : #{total_segments}")
log(logger, :info, "  Output           : #{OUTPUT_JSON}")

track_results.reject { |r| r[:ok] }.each do |r|
  log(logger, :warn, "  FAILED: #{r[:file]}")
end

if failed_count > 0
  log(logger, :warn, "  #{failed_count} track(s) failed — partial transcription.json retained")
end

exit 0
