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
require 'timeout'
require 'nokogiri'

# Spawns a child process and waits for it to finish.
# If timeout_seconds is given and the process exceeds it, sends SIGTERM and
# re-raises Timeout::Error so the caller can log context and return false.
def run_process_with_timeout(timeout_seconds, *cmd)
  pid = Process.spawn(*cmd)
  if timeout_seconds
    Timeout.timeout(timeout_seconds) { Process.waitpid(pid) }
  else
    Process.waitpid(pid)
  end
  $?.success?
rescue Timeout::Error
  begin
    Process.kill('TERM', pid)
    Process.waitpid(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    # process already gone
  end
  raise
end

# Accepts a single string or an array of strings. The value "disabled" (or a
# blank string) is silently skipped. Duplicate names are removed, keeping only
# the first occurrence.
#
# Examples:
#   "disabled"                          → []
#   "/path/to/openai_whisper.rb"        → [{ path: "...", name: "openai_whisper" }]
#   ["/path/openai_whisper.rb",
#    "/path/albert_whisper.rb"]         → [{ name: "openai_whisper", ... },
#                                          { name: "albert_whisper",  ... }]
def get_normalized_transcriber_paths(raw)
  paths = raw.is_a?(Array) ? raw : [raw.to_s]

  seen_names = {}
  paths.each_with_object([]) do |entry, result|
    str = entry.to_s.strip
    next if str.empty? || str == 'disabled'

    name = File.basename(str, '.rb')
    next if seen_names.key?(name)

    seen_names[name] = true
    result << { path: str, name: name }
  end
end

def deep_merge_hashes(base, override)
  base.merge(override) do |_key, base_val, override_val|
    if base_val.is_a?(Hash) && override_val.is_a?(Hash)
      deep_merge_hashes(base_val, override_val)
    else
      override_val
    end
  end
end

# Loads transcription.yml
def load_transcription_config
  production = File.expand_path(__dir__) == '/usr/local/bigbluebutton/core/scripts/post_archive'
  yml_path = if production
    '/usr/local/bigbluebutton/core/lib/transcription/transcription.yml'
  else
    File.expand_path('../../transcription/transcription.yml', __dir__)
  end

  config = File.exist?(yml_path) ? (YAML.safe_load(File.read(yml_path)) || {}) : {}

  override_path = '/etc/bigbluebutton/post-archive-transcription.yml'
  if File.exist?(override_path)
    override = YAML.safe_load(File.read(override_path)) || {}
    config = deep_merge_hashes(config, override)
  end

  config
end

# Detects the audio recording backend from events.xml.
# Returns :livekit when AudioTrackPublishedEvent is present (SFU / bbb-webrtc-sfu),
# :freeswitch when StartRecordingEvent is present (legacy FreeSWITCH bridge),
# or :livekit as a safe default when neither is found.
def detect_audio_backend(events_doc)
  return :livekit    if events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").any?
  return :freeswitch if events_doc.xpath("//event[@eventname='StartRecordingEvent']").any?
  :livekit
end

# Backend: custom transcribe.rb script
class CustomScriptBackend
  def initialize(custom_path)
    @script = custom_path
  end

  def available?
    !@script.nil? && File.executable?(@script)
  end

  def report_status
    BigBlueButton.logger.info("Back-end: #{@script}")
  end

  def transcribe(audio_file, output_json, events_xml, timeout_seconds: nil)
    BigBlueButton.logger.info("Running #{File.basename(@script)}: #{File.basename(audio_file)}")
    ok = run_process_with_timeout(timeout_seconds, @script, audio_file, output_json, events_xml,
                                  [:out, :err] => '/dev/null')

    if ok && File.exist?(output_json)
      BigBlueButton.logger.info("  -> #{File.basename(output_json)}")
      true
    else
      BigBlueButton.logger.error("Custom script failed for #{File.basename(audio_file)} (exit: #{$?.exitstatus})")
      false
    end
  rescue Timeout::Error
    BigBlueButton.logger.error("Custom script timed out after #{timeout_seconds}s: #{File.basename(audio_file)}")
    false
  end

  private
end

class Semaphore
  def initialize(count)
    @count = [count.to_i, 1].max
    @mutex = Mutex.new
    @cond  = ConditionVariable.new
  end

  def synchronize
    acquire
    yield
  ensure
    release
  end

  private

  def acquire
    @mutex.synchronize { @cond.wait(@mutex) while @count.zero?; @count -= 1 }
  end

  def release
    @mutex.synchronize { @count += 1; @cond.signal }
  end
end

def audio_duration_seconds(path)
  out = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{path}" 2>/dev/null`.strip
  out.empty? ? nil : out.to_f
rescue
  nil
end

def attempt_transcription(backend, audio_file, temp_json, events_xml, retry_config:)
  basename         = File.basename(audio_file)
  max_attempts     = retry_config[:max_attempts]
  wait             = retry_config[:initial_wait_seconds]

  duration_s       = audio_duration_seconds(audio_file) || 0
  dynamic_timeout  = (duration_s * retry_config[:transcription_timeout_factor]).ceil
  timeout_seconds  = [retry_config[:attempt_timeout_seconds], dynamic_timeout].max
  BigBlueButton.logger.info("  Max wait time for #{basename}: #{timeout_seconds}s " \
                            "(floor=#{retry_config[:attempt_timeout_seconds]}s, " \
                            "dynamic=#{dynamic_timeout}s from #{duration_s.round(1)}s audio)")

  max_attempts.times do |attempt|
    File.delete(temp_json) if File.exist?(temp_json)
    return true if backend.transcribe(audio_file, temp_json, events_xml, timeout_seconds: timeout_seconds)

    if attempt + 1 < max_attempts
      BigBlueButton.logger.warn("  Attempt #{attempt + 1}/#{max_attempts} failed for #{basename}, retrying in #{wait}s...")
      sleep(wait)
      wait *= 2
    end
  end

  false
end

def parse_track_result(temp_json, basename)
  raw      = JSON.parse(File.read(temp_json))
  segments = (raw['transcription'] || []).map do |s|
    seg = { 'offsets' => s['offsets'], 'text' => s['text'].to_s.strip }
    seg['speaker_id']  = s['speaker_id']  if s['speaker_id']
    seg['speaker_ids'] = s['speaker_ids'] if s['speaker_ids']
    seg
  end.reject { |s| s['text'].empty? }

  metadata = raw['metadata'] || {}
  BigBlueButton.logger.info("  #{basename}: #{segments.size} segment(s)")

  {
    file:            basename,
    segments:        segments,
    ok:              true,
    language:        raw['language'],
    config:          metadata['config'],
    quality_metrics: metadata['quality_metrics']
  }
rescue JSON::ParserError => e
  BigBlueButton.logger.error("Failed to parse temp JSON for #{basename}: #{e.message}")
  { file: basename, segments: [], ok: false }
end

def transcribe_audio_files(backend, audio_files, transcription_dir, events_xml, provider_name:, semaphore:, retry_config:)
  threads = audio_files.map do |audio_file|
    Thread.new do
      basename  = File.basename(audio_file)
      temp_json = File.join(transcription_dir, ".tmp_#{provider_name}_#{basename}.json")

      begin
        success = semaphore.synchronize do
          attempt_transcription(backend, audio_file, temp_json, events_xml, retry_config: retry_config)
        end
        next({ file: basename, segments: [], ok: false }) unless success

        parse_track_result(temp_json, basename)
      ensure
        File.delete(temp_json) if File.exist?(temp_json)
      end
    end
  end

  threads.map(&:value)
end

def resolve_active_backends(providers)
  if providers.any?
    active = providers.each_with_object([]) do |p, result|
      candidate = CustomScriptBackend.new(p[:path])
      if candidate.available?
        result << { name: p[:name], backend: candidate }
      else
        BigBlueButton.logger.warn("Provider '#{p[:name]}' not available at #{p[:path]} — skipping")
      end
    end

    if active.empty?
      BigBlueButton.logger.warn("No configured providers are available — skipping transcription.")
      exit 0
    end

    active
  else
    # Fall back to the bundled whisper_cpp.rb provider
    whisper_script = if File.expand_path(__dir__) == '/usr/local/bigbluebutton/core/scripts/post_archive'
      '/usr/local/bigbluebutton/core/lib/transcription/whisper_cpp.rb'
    else
      File.expand_path('../../transcription/whisper_cpp.rb', __dir__)
    end

    candidate = CustomScriptBackend.new(whisper_script)
    unless candidate.available?
      BigBlueButton.logger.error("whisper_cpp.rb not found or not executable at #{whisper_script}")
      BigBlueButton.logger.error("Install whisper.cpp or configure transcriber_path in transcription.yml")
      BigBlueButton.logger.warn("No transcription backend available — skipping transcription.")
      exit 0
    end

    BigBlueButton.logger.info("Back-end: whisper.cpp (built-in fallback via #{File.basename(whisper_script)})")
    [{ name: 'whisper_cpp', backend: candidate }]
  end
end

# Sums integer quality metric fields and averages float fields across all tracks.
# Returns nil when no track has quality_metrics (e.g. whisper.cpp fallback).
def aggregate_quality_metrics(track_results)
  metrics_list = track_results.filter_map { |r| r[:quality_metrics] }
  return nil if metrics_list.empty?

  logprob_values    = metrics_list.filter_map { |m| m['avg_logprob'] }
  no_speech_values  = metrics_list.filter_map { |m| m['avg_no_speech_prob'] }
  coverage_values   = metrics_list.filter_map { |m| m['coverage_ratio'] }
  total_chunks      = metrics_list.sum { |m| m['total_chunks'].to_i }
  accepted_chunks   = metrics_list.sum { |m| m['accepted_chunks'].to_i }

  {
    'total_chunks'                => total_chunks,
    'accepted_chunks'             => accepted_chunks,
    'rejected_chunks'             => metrics_list.sum { |m| m['rejected_chunks'].to_i },
    'total_words'                 => metrics_list.sum { |m| m['total_words'].to_i },
    'silence_hallucination_count' => metrics_list.sum { |m| m['silence_hallucination_count'].to_i },
    'repetition_score'            => metrics_list.map { |m| m['repetition_score'].to_f }.then { |a| a.empty? ? 0.0 : (a.sum / a.size).round(4) },
    'known_phrase_hits'           => metrics_list.flat_map { |m| m['known_phrase_hits'] || [] }.uniq,
    'avg_logprob'                 => logprob_values.empty?   ? nil : (logprob_values.sum   / logprob_values.size).round(4),
    'avg_no_speech_prob'          => no_speech_values.empty? ? nil : (no_speech_values.sum / no_speech_values.size).round(4),
    'coverage_ratio'              => coverage_values.empty?  ? nil : (coverage_values.sum  / coverage_values.size).round(4)
  }
end

def run_provider_transcription(provider, audio_files, transcription_dir, events_xml, meeting_id, canonical_path, audio_semaphore:, retry_config:)
  BigBlueButton.logger.info("=== Provider: #{provider[:name]} ===")
  provider[:backend].report_status

  track_results = transcribe_audio_files(
    provider[:backend], audio_files, transcription_dir, events_xml,
    provider_name: provider[:name],
    semaphore:     audio_semaphore,
    retry_config:  retry_config
  )

  detected_language = track_results.filter_map { |r| r[:language] }.first

  merged = {
    'meeting_id'   => meeting_id,
    'generated_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ'),
    'provider'     => provider[:name],
    'tracks'       => track_results.map { |r| { 'file' => r[:file], 'segments' => r[:segments] } }
  }
  merged['language'] = detected_language if detected_language
  provider_config  = track_results.filter_map { |r| r[:config] }.first
  provider_metrics = aggregate_quality_metrics(track_results)
  merged['metadata'] = { 'config' => provider_config, 'quality_metrics' => provider_metrics }.compact
  merged.delete('metadata') if merged['metadata'].empty?

  provider_json = File.join(transcription_dir, "transcription_#{provider[:name]}.json")
  File.write(provider_json, JSON.pretty_generate(merged))
  BigBlueButton.logger.info("Written: #{provider_json}")

  if canonical_path
    File.write(canonical_path, JSON.pretty_generate(merged))
    BigBlueButton.logger.info("Written: #{canonical_path} (canonical, from '#{provider[:name]}')")
  end

  {
    name:           provider[:name],
    track_results:  track_results,
    ok_count:       track_results.count { |r|  r[:ok] },
    failed_count:   track_results.count { |r| !r[:ok] },
    total_segments: track_results.sum   { |r|  r[:segments].size }
  }
end

# CLI
opts = Optimist::options do
  opt :meeting_id, 'Meeting id', type: String
end

transcription_props = load_transcription_config

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

logger = Logger.new(log_path)
logger.level = Logger::INFO
BigBlueButton.logger = logger

BigBlueButton.logger.info("Meeting ID : #{meeting_id}")

# Paths + audio discovery
raw_dir           = "#{recording_dir}/raw/#{meeting_id}"
audio_dir         = "#{raw_dir}/audio"
transcription_dir = "#{raw_dir}/transcription"

unless Dir.exist?(raw_dir)
  BigBlueButton.logger.error("Raw recording directory not found: #{raw_dir}")
  exit 1
end

FileUtils.mkdir_p(transcription_dir)
BigBlueButton.logger.info("Transcription output: #{transcription_dir}")

AUDIO_EXTENSIONS = %w[webm opus mp3 wav ogg m4a flac].freeze

audio_files = AUDIO_EXTENSIONS.flat_map { |ext| Dir.glob("#{audio_dir}/*.#{ext}") }.sort

if audio_files.empty?
  BigBlueButton.logger.warn("No audio files found in #{audio_dir} — nothing to transcribe.")
  exit 0
end

BigBlueButton.logger.info("Found #{audio_files.size} audio file(s)")

providers       = get_normalized_transcriber_paths(transcription_props['transcriber_path'])
active_backends = resolve_active_backends(providers)

BigBlueButton.logger.info("Active provider(s): #{active_backends.map { |b| b[:name] }.join(', ')}")

start_time = Time.now

# Skip if canonical output already exists
OUTPUT_JSON = File.join(transcription_dir, 'transcription.json').freeze

if File.exist?(OUTPUT_JSON)
  BigBlueButton.logger.info("transcription.json already exists — skipping (delete it to re-run)")
  exit 0
end

events_xml = File.join(raw_dir, 'events.xml')

audio_backend = if File.exist?(events_xml)
  detect_audio_backend(Nokogiri::XML(File.read(events_xml)))
else
  BigBlueButton.logger.warn("events.xml not found — defaulting to livekit backend")
  :livekit
end
ENV['BBB_AUDIO_BACKEND'] = audio_backend.to_s
BigBlueButton.logger.info("Audio backend: #{audio_backend}")

max_parallel_providers   = (transcription_props['max_parallel_providers']   || 1).to_i
max_parallel_audio_files = (transcription_props['max_parallel_audio_files'] || 1).to_i

BigBlueButton.logger.info("Parallelism: providers=#{max_parallel_providers}, audio_files=#{max_parallel_audio_files}")

retry_cfg    = transcription_props.fetch('retry', {})
max_attempts         = (retry_cfg['max_attempts']         || 5).to_i
initial_wait_seconds = (retry_cfg['initial_wait_seconds'] || 5).to_i
retry_config = {
  max_attempts:               max_attempts,
  initial_wait_seconds:       initial_wait_seconds,
  attempt_timeout_seconds:    initial_wait_seconds * (2**max_attempts - 1),
  transcription_timeout_factor: (transcription_props['transcription_timeout_factor'] || 0.5).to_f
}

BigBlueButton.logger.info("Retry: max_attempts=#{retry_config[:max_attempts]}, " \
                          "initial_wait=#{retry_config[:initial_wait_seconds]}s, " \
                          "timeout_floor=#{retry_config[:attempt_timeout_seconds]}s, " \
                          "transcription_timeout_factor=#{retry_config[:transcription_timeout_factor]}")

provider_semaphore = Semaphore.new(max_parallel_providers)
audio_semaphore    = Semaphore.new(max_parallel_audio_files)

provider_threads = active_backends.each_with_index.map do |entry, idx|
  canonical = idx.zero? ? OUTPUT_JSON : nil
  Thread.new do
    provider_semaphore.synchronize do
      run_provider_transcription(entry, audio_files, transcription_dir, events_xml, meeting_id, canonical,
                                 audio_semaphore: audio_semaphore,
                                 retry_config:    retry_config)
    end
  end
end

provider_summaries = provider_threads.map(&:value)

BigBlueButton.logger.info("=== Transcription complete ===")
BigBlueButton.logger.info("  Providers run    : #{provider_summaries.size}")

provider_summaries.each do |ps|
  BigBlueButton.logger.info("  [#{ps[:name]}] tracks succeeded: #{ps[:ok_count]} / #{audio_files.size}, segments: #{ps[:total_segments]}")
  ps[:track_results].reject { |r| r[:ok] }.each do |r|
    BigBlueButton.logger.warn("  [#{ps[:name]}] FAILED: #{r[:file]}")
  end
  if ps[:failed_count] > 0
    BigBlueButton.logger.warn("  [#{ps[:name]}] #{ps[:failed_count]} track(s) failed — partial output retained")
  end
end

BigBlueButton.logger.info("  Canonical output : #{OUTPUT_JSON}")
BigBlueButton.logger.info("  Elapsed time  : #{(Time.now - start_time).round(1)}s")
BigBlueButton.logger.info("  (Processes for providers: #{max_parallel_providers})")
BigBlueButton.logger.info("  (Processes for audio files: #{max_parallel_audio_files})")

exit 0
