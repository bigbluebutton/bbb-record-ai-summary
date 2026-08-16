# Set encoding to utf-8
# encoding: UTF-8

#
# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/
#
# Copyright (c) 2019 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.
#

require File.expand_path('../../../lib/recordandplayback', __FILE__)
require 'rubygems'
require 'optimist'
require 'yaml'
require 'builder'

FORMAT_NAME = 'ai-summary'.freeze

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

# Loads the ai-summary format config from +path+ and applies an optional
def load_format_config(path)
  cfg = YAML.safe_load(File.read(path)) || {}

  override_path = '/etc/bigbluebutton/ai-summary.yml'
  if File.exist?(override_path)
    override = YAML.safe_load(File.read(override_path)) || {}
    cfg = deep_merge_hashes(cfg, override)
  end

  cfg
end

# Helper method to parse meeting ID and playback format.
# Strips the known "-ai-summary" suffix rather than splitting on the last hyphen,
# because the format name itself contains a hyphen.
def parse_meeting_id(meeting_id_with_format)
  suffix = "-#{FORMAT_NAME}"
  meeting_id = meeting_id_with_format.delete_suffix(suffix)
  format     = meeting_id_with_format.end_with?(suffix) ? FORMAT_NAME : nil
  [meeting_id, format]
end

# Helper method to convert markdown to PDF using pandoc
def convert_markdown_to_pdf(source_md, output_pdf, logger)
  unless File.exist?(source_md)
    logger.warn("ai-summary.md not found at #{source_md}, skipping PDF generation")
    return false
  end

  logger.info("Converting ai-summary.md to PDF with pandoc")
  logger.info("Source: #{source_md}")
  logger.info("Output: #{output_pdf}")

  pandoc_cmd = "pandoc '#{source_md}' -o '#{output_pdf}' --pdf-engine=xelatex 2>&1"
  result = `#{pandoc_cmd}`

  if $?.success? && File.exist?(output_pdf)
    logger.info("Successfully generated PDF from markdown using pandoc")
    logger.info("PDF size: #{File.size(output_pdf)} bytes")
    true
  else
    logger.error("Pandoc conversion failed: #{result}")
    false
  end
end

STATIC_PUBLISHED_FILES = [
  { filename: 'ai-summary.pdf',     type: 'pdf',  category: 'summary'       },
  { filename: 'ai-summary.md',      type: 'md',   category: 'summary'       },
  { filename: 'ai-summary.html',    type: 'html', category: 'summary'       },
  { filename: 'ai-summary.json',    type: 'json', category: 'summary'       },
  { filename: 'transcription.json', type: 'json', category: 'transcription' },
  { filename: 'transcription.vtt',  type: 'vtt',  category: 'transcription' },
].freeze

# --- Metrics ----------------------------------------------------------------
# See the matching block in process/ai-summary.rb for why this is logfmt and
# why every line carries a run_id.

def ai_summary_run_id
  $ai_summary_run_id ||= "#{(Time.now.utc.to_f * 1000).to_i}-#{Process.pid}"
end

def ai_summary_monotonic_ms
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
end

def ai_summary_logfmt(fields)
  fields.reject { |_k, v| v.nil? || v.to_s.empty? }.map do |key, value|
    text = value.to_s
    text.match?(/\A[\w.:+-]+\z/) ? "#{key}=#{text}" : "#{key}=#{text.inspect}"
  end.join(' ')
end

def emit_ai_summary_metrics(logger, fields)
  logger.info("AI_SUMMARY_METRICS v=1 #{ai_summary_logfmt(fields)}")
end

def read_json_or_nil(path)
  JSON.parse(File.read(path))
rescue StandardError
  nil
end

# Adds bbb-ai-summary-* keys to <meta>, which getRecordings returns verbatim in
# <metadata> and can filter on. This is where whole-pipeline numbers live;
# <playback><processing_time> stays the process step only, so it remains
# comparable with every other recording format.
def add_ai_summary_meta(metadata_path, fields, logger)
  doc = File.open(metadata_path) { |f| Nokogiri::XML(f) }
  meta = doc.at_xpath('recording/meta')
  unless meta
    meta = Nokogiri::XML::Node.new('meta', doc)
    doc.at('recording').add_child(meta)
  end
  fields.reject { |_k, v| v.nil? || v.to_s.empty? }.each do |key, value|
    meta.at_xpath(key.to_s)&.remove # keep reruns idempotent
    node = Nokogiri::XML::Node.new(key.to_s, doc)
    node.content = value.to_s # Nokogiri escapes; values include provider/model strings from YAML
    meta.add_child(node)
  end
  File.write(metadata_path, Nokogiri::XML(doc.to_xml) { |x| x.noblanks }.root)
  logger.info("Added ai-summary timing metadata to metadata.xml")
end
# ----------------------------------------------------------------------------

# Helper method to update metadata.xml with playback information
def update_metadata_with_playback(metadata_path, playback_protocol, playback_host, meeting_id, format, recording_time, published_files, logger, processing_time: nil)
  logger.info("Updating metadata.xml with playback information")

  metadata = File.open(metadata_path) { |f| Nokogiri::XML(f) }
  recording = metadata.root

  # Update state and published status
  recording.at_xpath("state").content = "published"
  recording.at_xpath("published").content = "true"

  # Remove empty playback nodes
  metadata.search('//recording/playback').each(&:remove)

  # Add playback information
  base_url = "#{playback_protocol}://#{playback_host}/ai-summary/#{meeting_id}"
  Nokogiri::XML::Builder.with(metadata.at('recording')) do |xml|
    xml.playback {
      xml.format("ai-summary")
      xml.link("#{base_url}/ai-summary.#{format}")
      # Same element, same position, as publish/presentation.rb. bbb-web maps it
      # to <processingTime> in getRecordings; without it the API reports 0.
      xml.processing_time(processing_time.to_s) if processing_time
      xml.duration(recording_time.to_s)
      xml.extensions {
        xml.urls {
          published_files.each do |f|
            xml.url("#{base_url}/#{f[:filename]}", type: f[:type], category: f[:category])
          end
        }
      }
    }
  end

  # Write updated metadata
  formatted = Nokogiri::XML(metadata.to_xml) { |x| x.noblanks }
  File.write(metadata_path, formatted.root)
  logger.info("Added playback to metadata.xml")
end

def copy_provider_transcriptions(process_dir, target_dir, logger)
  Dir.glob("#{process_dir}/transcript_diarized_*.json").sort.map do |src|
    provider_name = File.basename(src, '.json').delete_prefix('transcript_diarized_')
    dest_name     = "transcription_#{provider_name}.json"
    FileUtils.cp(src, "#{target_dir}/#{dest_name}")
    logger.info("Copied #{dest_name} to publish directory")
    dest_name
  end
end

def copy_process_file_to_publish_dir(filename_source, filename_target, process_dir, target_dir, logger)
  source = "#{process_dir}/#{filename_source}"
  if File.exist?(source)
    FileUtils.cp(source, "#{target_dir}/#{filename_target}")
    logger.info("Copied #{filename_source} to publish directory")
  else
    logger.warn("No #{filename_source} found in process dir, skipping.")
  end
end

# Parse command line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :default => '58f4a6b3-cd07-444d-8564-59116cb53974', :type => String
end

# Parse meeting ID and format
meeting_id, playback = parse_meeting_id(opts[:meeting_id])

# Early exit if not ai-summary format
exit 0 unless playback == "ai-summary"

bbb_props    = BigBlueButton.read_props
format_props = load_format_config('ai-summary.yml')

# Set up paths
log_dir = bbb_props['log_dir']
recording_dir = bbb_props['recording_dir']
raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
process_dir = "#{recording_dir}/process/ai-summary/#{meeting_id}"
publish_dir = format_props['publish_dir']
format = format_props['format']
playback_protocol = bbb_props['playback_protocol']
playback_host = bbb_props['playback_host']
target_dir = "#{recording_dir}/publish/ai-summary/#{meeting_id}"

# Set up logger
FileUtils.mkdir_p "#{log_dir}/ai-summary"
logger = Logger.new("#{log_dir}/ai-summary/publish-#{meeting_id}.log", 'daily')
BigBlueButton.logger = logger

# Early exit if already published to final destination
final_publish_dir = "#{publish_dir}/#{meeting_id}"
if FileTest.directory?(final_publish_dir)
  BigBlueButton.logger.info("#{final_publish_dir} is already published")
  exit 0
end

begin
  BigBlueButton.logger.info("AI_SUMMARY_RUN_START v=1 " + ai_summary_logfmt(
    stage: 'publish', meeting_id: meeting_id, run_id: ai_summary_run_id
  ))
  publish_started_ms = ai_summary_monotonic_ms

  # Read every timing input while the process dir still exists — it is deleted
  # at the end of this script (and by the publish worker), which is why these
  # numbers never reached the published metadata before.
  #
  # processing_time is written by BBB's process worker after the process script
  # exits, and only when it ran under the worker; a manual rerun (see
  # OPERATIONS.md) leaves it absent, so fall back to the script's own measurement.
  worker_process_ms = if File.exist?("#{process_dir}/processing_time")
                        File.read("#{process_dir}/processing_time").to_i
                      end
  process_timings = read_json_or_nil("#{process_dir}/ai-summary-timings.json")
  transcription_timings = read_json_or_nil("#{raw_archive_dir}/transcription/ai-summary-timings.json")
  process_ms_source = worker_process_ms ? 'worker' : 'script'
  process_ms = worker_process_ms || process_timings&.dig('script_ms')

  # Create target directory (remove first to clear any leftover state from a previous failed run)
  BigBlueButton.logger.info("Making dir #{target_dir}")
  FileUtils.rm_rf(target_dir) if File.exist?(target_dir)
  FileUtils.mkdir_p target_dir

  # Convert markdown to PDF if available
  source_md = "#{process_dir}/ai-summary.md"
  output_pdf = "#{target_dir}/ai-summary.pdf"

  pdf_started_ms = ai_summary_monotonic_ms
  convert_markdown_to_pdf(source_md, output_pdf, BigBlueButton.logger)
  pdf_ms = ai_summary_monotonic_ms - pdf_started_ms

  copy_process_file_to_publish_dir("ai-summary.md", "ai-summary.md", process_dir, target_dir, BigBlueButton.logger)

  copy_process_file_to_publish_dir("ai-summary.html", "ai-summary.html", process_dir, target_dir, BigBlueButton.logger)

  copy_process_file_to_publish_dir("ai-summary.json", "ai-summary.json", process_dir, target_dir, BigBlueButton.logger)
  
  copy_process_file_to_publish_dir("transcript_diarized.vtt", "transcription.vtt", process_dir, target_dir, BigBlueButton.logger)
  
  copy_process_file_to_publish_dir("transcript_diarized.json", "transcription.json", process_dir, target_dir, BigBlueButton.logger)

  provider_transcription_files = copy_provider_transcriptions(process_dir, target_dir, BigBlueButton.logger)

  # Get recording duration
  events_doc = File.open("#{raw_archive_dir}/events.xml") { |f| Nokogiri::XML(f) }
  recording_time = BigBlueButton::Events.get_recording_length(events_doc)

  # Copy and update metadata.xml
  BigBlueButton.logger.info("Creating metadata.xml")
  FileUtils.cp("#{process_dir}/metadata.xml", target_dir)
  BigBlueButton.logger.info("Copied metadata.xml file")

  # Collect all published files: static files that exist + dynamic provider transcriptions
  static_files   = STATIC_PUBLISHED_FILES.select { |f| File.exist?("#{target_dir}/#{f[:filename]}") }
  provider_files = provider_transcription_files.map { |fn| { filename: fn, type: 'json', category: 'transcription' } }
  published_files = static_files + provider_files

  metadata_path = "#{target_dir}/metadata.xml"
  update_metadata_with_playback(metadata_path, playback_protocol, playback_host, meeting_id, format, recording_time, published_files, BigBlueButton.logger, processing_time: process_ms)

  # Ensure publish directory exists
  FileUtils.mkdir_p(publish_dir) unless FileTest.directory?(publish_dir)

  # Add file size metadata
  raw_dir = "#{recording_dir}/raw/#{meeting_id}"
  BigBlueButton.add_raw_size_to_metadata(target_dir, raw_dir)
  BigBlueButton.add_playback_size_to_metadata(target_dir)

  # Whole-pipeline rollup. total_ms sums the stage durations; it excludes the
  # queue waits between workers, so it is processing cost, not user-perceived
  # latency.
  transcription_ms = transcription_timings&.dig('wall_ms')
  publish_ms = ai_summary_monotonic_ms - publish_started_ms
  total_ms = [transcription_ms, process_ms, publish_ms].compact.sum
  summary_present = process_timings.nil? ? nil : process_timings['summary_present']
  status = if summary_present.nil? then nil
           elsif summary_present then 'ok'
           else 'no-summary'
           end

  add_ai_summary_meta(metadata_path, {
    'bbb-ai-summary-status'           => status,
    'bbb-ai-summary-total-ms'         => total_ms,
    'bbb-ai-summary-transcription-ms' => transcription_ms,
    'bbb-ai-summary-process-ms'       => process_ms,
    'bbb-ai-summary-publish-ms'       => publish_ms,
    'bbb-ai-summary-llm-ms'           => process_timings&.dig('llm_total_ms'),
    'bbb-ai-summary-llm-provider'     => process_timings&.dig('llm_provider'),
    'bbb-ai-summary-asr-provider'     => transcription_timings&.dig('canonical_provider')
  }, BigBlueButton.logger)

  emit_ai_summary_metrics(BigBlueButton.logger,
                          stage: 'publish', meeting_id: meeting_id, run_id: ai_summary_run_id,
                          outcome: 'ok', script_ms: publish_ms, pdf_ms: pdf_ms,
                          process_ms: process_ms, process_ms_source: process_ms_source)

  emit_ai_summary_metrics(BigBlueButton.logger,
                          stage: 'pipeline', meeting_id: meeting_id, run_id: ai_summary_run_id,
                          outcome: 'ok', status: status,
                          asr_provider: transcription_timings&.dig('canonical_provider'),
                          llm_provider: process_timings&.dig('llm_provider'),
                          llm_model: process_timings&.dig('llm_model'),
                          transcription_ms: transcription_ms,
                          transcription_run_id: transcription_timings&.dig('run_id'),
                          process_ms: process_ms,
                          llm_summary_ms: process_timings&.dig('llm_summary_ms'),
                          llm_action_items_ms: process_timings&.dig('llm_action_items_ms'),
                          publish_ms: publish_ms, pdf_ms: pdf_ms, total_ms: total_ms,
                          complete: [transcription_ms, process_ms, publish_ms].none?(&:nil?))

  # Copy to final publish location if different
  unless target_dir == final_publish_dir
    FileUtils.cp_r(target_dir, publish_dir)
    BigBlueButton.logger.info("Copied files to #{publish_dir}")
  else
    BigBlueButton.logger.info("Files already in publish location: #{target_dir}")
  end

  BigBlueButton.logger.info("Finished publishing script ai-summary.rb successfully.")

  BigBlueButton.logger.info("Removing processed files.")
  FileUtils.rm_r(process_dir)

  BigBlueButton.logger.info("Removing published files.")
  FileUtils.rm_r(target_dir)

  # Write success status file
  File.write("#{recording_dir}/status/published/#{meeting_id}-ai-summary.done", "Published #{meeting_id}")

rescue Exception => e
  BigBlueButton.logger.error(e.message)
  e.backtrace.each do |traceline|
    BigBlueButton.logger.error(traceline)
  end

  emit_ai_summary_metrics(BigBlueButton.logger,
                          stage: 'publish', meeting_id: meeting_id, run_id: ai_summary_run_id,
                          outcome: 'failed', error_class: e.class.name,
                          script_ms: (defined?(publish_started_ms) ? ai_summary_monotonic_ms - publish_started_ms : nil))

  # Write failure status file
  File.write("#{recording_dir}/status/published/#{meeting_id}-ai-summary.fail", "Failed Publishing #{meeting_id}")
  exit 1
end
