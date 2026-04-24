#!/usr/bin/env ruby
# encoding: UTF-8
#
# whisper_cpp.rb — Transcription via whisper.cpp (local fallback backend).
#
# Deploy as transcribe.rb in the transcription lib dir, or leave as whisper_cpp.rb
# so it is picked up automatically as the built-in fallback when no other provider
# is configured via transcriber_path in transcription.yml.
#
# Called by transcribe_audio.rb as:
#   whisper_cpp.rb <audio_file> <output_json_file> <events_xml_file>
#
# Binary and model are located automatically via BINARY_SEARCH_PATHS and
# MODEL_SEARCH_DIRS. Override via environment variables:
#   WHISPER_BINARY  — full path to whisper-cli
#   WHISPER_MODEL   — full path to the ggml model file
#
# Output format (as expected by transcribe_audio.rb):
#   {
#     "transcription": [
#       { "offsets": { "from": <ms>, "to": <ms> }, "text": "..." },
#       ...
#     ]
#   }
#

require 'json'
require 'yaml'
require 'logger'
require 'fileutils'
require_relative 'transcription_utils'

BINARY_SEARCH_PATHS = [
  '/usr/local/bin/whisper.cpp/build/bin/whisper-cli',
  '/usr/local/bin/whisper.cpp/main',
  File.join(File.expand_path(__dir__), 'whisper.cpp', 'build', 'bin', 'whisper-cli'),
  File.join(File.expand_path(__dir__), 'whisper.cpp', 'main'),
  '/usr/local/bigbluebutton/core/whisper.cpp/build/bin/whisper-cli',
  '/usr/local/bigbluebutton/core/whisper.cpp/main',
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

def find_binary
  path = ENV['WHISPER_BINARY'].to_s.strip
  return path if !path.empty? && File.executable?(path)
  BINARY_SEARCH_PATHS.find { |p| File.executable?(p) }
end

def find_model
  path = ENV['WHISPER_MODEL'].to_s.strip
  return path if !path.empty? && File.exist?(path)
  MODEL_SEARCH_DIRS.each do |dir|
    next unless Dir.exist?(dir)
    model = Dir.glob("#{dir}/ggml-base.en.bin").first ||
            Dir.glob("#{dir}/ggml-*.bin").min_by { |f| File.size(f) }
    return model if model
  end
  nil
end

# Arguments
audio_file  = ARGV[0]
output_json = ARGV[1]
events_xml  = ARGV[2]

die "Usage: whisper_cpp.rb <audio_file> <output_json_file> <events_xml_file>" \
  if audio_file.nil? || audio_file.strip.empty? ||
     output_json.nil? || output_json.strip.empty? ||
     events_xml.nil? || events_xml.strip.empty?

die "Audio file not found: #{audio_file}" unless File.exist?(audio_file)
die "Events XML not found: #{events_xml}"  unless File.exist?(events_xml)

# Logger setup — mirrors albert_whisper.rb
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
$logger = Logger.new(File.join(log_dir, "post_archive-transcribe-whisper_cpp-#{meeting_id}.log"))
$logger.level = Logger::INFO

# Locate binary and model
binary = find_binary
die "whisper.cpp binary not found. Searched:\n  #{BINARY_SEARCH_PATHS.join("\n  ")}\n" \
    "Install whisper.cpp or set WHISPER_BINARY." unless binary

model = find_model
die "No whisper model found. Searched dirs:\n  #{MODEL_SEARCH_DIRS.join("\n  ")}\n" \
    "Download a ggml model or set WHISPER_MODEL." unless model

info "Binary: #{binary}"
info "Model : #{model}"

# Prepare audio chunks via events.xml
livekit = ENV.fetch('BBB_AUDIO_BACKEND', 'livekit') != 'freeswitch'
result  = TranscriptionUtils.prepare_audio_chunks(audio_file, events_xml,
                                                  livekit:      livekit,
                                                  merge_gap_ms: TranscriptionUtils::MERGE_GAP_MS)
die "Audio conversion failed — ffmpeg is required." if result.nil?

info "Audio: #{File.basename(audio_file)} (#{(File.size(result[:work_file]) / 1024.0).round(1)} KB)"

chunks = result[:chunks]

if chunks.empty?
  TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
  File.write(output_json, JSON.generate({ 'transcription' => [] }))
  info "Written 0 segment(s) to #{File.basename(output_json)}"
  exit 0
end

info "Chunks: #{chunks.size}"

all_segments = []

chunks.each_with_index do |chunk, i|
  info "Chunk #{i + 1}/#{chunks.size}: #{chunk[:from_ms]}ms – #{chunk[:to_ms]}ms"
  chunk_prefix = chunk[:path].delete_suffix('.wav')

  ok = system(
    binary, '-m', model,
    '-f', chunk[:path], '-l', 'auto',
    '-oj', '-of', chunk_prefix,
    [:out, :err] => '/dev/null'
  )

  whisper_out = "#{chunk_prefix}.json"
  unless ok && File.exist?(whisper_out)
    info "  Chunk #{i + 1} failed, skipping"
    next
  end

  begin
    data = JSON.parse(File.read(whisper_out))
    segs = (data['transcription'] || []).filter_map do |s|
      text = s['text'].to_s.strip
      next if text.empty?
      seg = {
        'offsets' => {
          'from' => chunk[:from_ms] + s.dig('offsets', 'from').to_i,
          'to'   => chunk[:from_ms] + s.dig('offsets', 'to').to_i
        },
        'text' => text
      }
      seg['speaker_id'] = chunk[:speaker_id] if chunk[:speaker_id]
      seg
    end
    all_segments.concat(segs)
    info "  -> #{segs.size} segment(s)"
  rescue JSON::ParserError => e
    info "  Could not parse whisper output for chunk #{i + 1}: #{e.message}"
  ensure
    File.delete(whisper_out) if File.exist?(whisper_out)
  end
end

TranscriptionUtils.cleanup_chunks(result[:chunks_dir], result[:temp_wav])
File.write(output_json, JSON.generate({ 'transcription' => all_segments }))
info "Written #{all_segments.size} segment(s) to #{File.basename(output_json)}"
