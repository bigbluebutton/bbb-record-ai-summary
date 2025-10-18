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

# For PRODUCTION - Use system library
require '/usr/local/bigbluebutton/core/lib/recordandplayback'
require 'rubygems'
require 'optimist'
require 'yaml'
require 'builder'

# Helper method to parse meeting ID and playback format
def parse_meeting_id(meeting_id_with_format)
  match = /(.*)-(.*)/.match(meeting_id_with_format)
  [match[1], match[2]]  # Returns [meeting_id, playback_format]
end

# Helper method to convert markdown to PDF using pandoc
def convert_markdown_to_pdf(source_md, output_pdf, target_dir, note_file, logger)
  unless File.exist?(source_md)
    logger.warn("notes.md not found at #{source_md}, using original PDF")
    FileUtils.cp(note_file, target_dir)
    return false
  end

  logger.info("Converting notes.md to PDF with pandoc")
  logger.info("Source: #{source_md}")
  logger.info("Output: #{output_pdf}")

  pandoc_cmd = "pandoc '#{source_md}' -o '#{output_pdf}' --pdf-engine=pdflatex 2>&1"
  result = `#{pandoc_cmd}`

  if $?.success? && File.exist?(output_pdf)
    logger.info("Successfully generated PDF from markdown using pandoc")
    logger.info("PDF size: #{File.size(output_pdf)} bytes")

    # Also copy the markdown file to publish directory
    FileUtils.cp(source_md, "#{target_dir}/notes.md")
    logger.info("Copied notes.md to publish directory")
    true
  else
    logger.error("Pandoc conversion failed: #{result}")
    logger.warn("Falling back to original PDF")
    FileUtils.cp(note_file, target_dir)
    false
  end
end

# Helper method to update metadata.xml with playback information
def update_metadata_with_playback(metadata_path, playback_protocol, playback_host, meeting_id, format, recording_time, logger)
  logger.info("Updating metadata.xml with playback information")

  metadata = Nokogiri::XML(File.open(metadata_path))
  recording = metadata.root

  # Update state and published status
  recording.at_xpath("state").content = "published"
  recording.at_xpath("published").content = "true"

  # Remove empty playback nodes
  metadata.search('//recording/playback').each(&:remove)

  # Add playback information
  Nokogiri::XML::Builder.with(metadata.at('recording')) do |xml|
    xml.playback {
      xml.format("notes")
      xml.link("#{playback_protocol}://#{playback_host}/notes/#{meeting_id}/notes.#{format}")
      xml.duration(recording_time.to_s)
    }
  end

  # Write updated metadata
  formatted = Nokogiri::XML(metadata.to_xml) { |x| x.noblanks }
  File.write(metadata_path, formatted.root)
  logger.info("Added playback to metadata.xml")
end

# Parse command line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :default => '58f4a6b3-cd07-444d-8564-59116cb53974', :type => String
end

# Parse meeting ID and format
meeting_id, playback = parse_meeting_id(opts[:meeting_id])

# Early exit if not notes format
exit 0 unless playback == "notes"

# Load configuration from local config directory for development
script_dir = File.expand_path(File.dirname(__FILE__))
project_root = File.expand_path('../..', script_dir)
bbb_props = YAML::load(File.open("#{project_root}/config/bigbluebutton.yml"))
notes_props = YAML::load(File.open("#{project_root}/config/notes.yml"))

# Set up paths
log_dir = bbb_props['log_dir']
recording_dir = bbb_props['recording_dir']
raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
process_dir = "#{recording_dir}/process/notes/#{meeting_id}"
publish_dir = notes_props['publish_dir']
format = notes_props['format']
playback_protocol = bbb_props['playback_protocol']
playback_host = bbb_props['playback_host']
target_dir = "#{recording_dir}/publish/notes/#{meeting_id}"

# Set up logger
logger = Logger.new("#{log_dir}/notes/publish-#{meeting_id}.log", 'daily')
BigBlueButton.logger = logger

# Early exit if already published
if FileTest.directory?(target_dir)
  BigBlueButton.logger.info("#{target_dir} is already there")
  exit 0
end

begin
  # Create target directory
  BigBlueButton.logger.info("Making dir target_dir")
  FileUtils.mkdir_p target_dir

  # Check if notes file exists
  note_file = "#{process_dir}/notes.#{format}"
  unless File.exist?(note_file)
    BigBlueButton.logger.info("There wasn't any note for #{meeting_id}")
    File.write("#{recording_dir}/status/published/#{meeting_id}-notes.done", "Published #{meeting_id}")
    exit 0
  end

  BigBlueButton.logger.info("Original notes file: #{note_file}")

  # Convert markdown to PDF
  source_md = "#{process_dir}/notes.md"
  output_pdf = "#{target_dir}/notes.pdf"
  convert_markdown_to_pdf(source_md, output_pdf, target_dir, note_file, BigBlueButton.logger)

  # Get recording duration
  events_doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))
  recording_time = BigBlueButton::Events.get_recording_length(events_doc)

  # Copy and update metadata.xml
  BigBlueButton.logger.info("Creating metadata.xml")
  FileUtils.cp("#{process_dir}/metadata.xml", target_dir)
  BigBlueButton.logger.info("Copied metadata.xml file")

  metadata_path = "#{target_dir}/metadata.xml"
  update_metadata_with_playback(metadata_path, playback_protocol, playback_host, meeting_id, format, recording_time, BigBlueButton.logger)

  # Ensure publish directory exists
  FileUtils.mkdir_p(publish_dir) unless FileTest.directory?(publish_dir)

  # Add file size metadata
  raw_dir = "#{recording_dir}/raw/#{meeting_id}"
  BigBlueButton.add_raw_size_to_metadata(target_dir, raw_dir)
  BigBlueButton.add_playback_size_to_metadata(target_dir)

  # Copy to final publish location if different
  final_publish_dir = "#{publish_dir}/#{meeting_id}"
  unless target_dir == final_publish_dir
    FileUtils.cp_r(target_dir, publish_dir)
    BigBlueButton.logger.info("Copied files to #{publish_dir}")
  else
    BigBlueButton.logger.info("Files already in publish location: #{target_dir}")
  end

  BigBlueButton.logger.info("Finished publishing script notes.rb successfully.")

  # Write success status file
  File.write("#{recording_dir}/status/published/#{meeting_id}-notes.done", "Published #{meeting_id}")

rescue Exception => e
  BigBlueButton.logger.error(e.message)
  e.backtrace.each do |traceline|
    BigBlueButton.logger.error(traceline)
  end

  # Write failure status file
  File.write("#{recording_dir}/status/published/#{meeting_id}-notes.fail", "Failed Publishing #{meeting_id}")
  exit 1
end
