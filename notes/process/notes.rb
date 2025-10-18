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
require 'json'

# Helper method to convert HTML to plain text
def html_to_plain_text(html_content)
  return "" if html_content.nil? || html_content.empty?

  text = html_content.dup
  # Remove style, script, and head tags with their content
  text.gsub!(/<(style|script|head)[^>]*>.*?<\/\1>/im, '')
  # Strip remaining HTML tags
  text.gsub!(/<[^>]*>/, "\n")
  # Remove HTML entities (numeric and named)
  text.gsub!(/&#\d+;|&[a-z]+;/i, ' ')
  # Remove Etherpad IDs (e.g., g.xxxxx$notes)
  text.gsub!(/^g\.\w+\$\w+\s*$/m, '')
  text.strip
end

# Helper method to build markdown content
def build_markdown_content(text_content, word_count)
  [
    "# Shared Notes",
    "",
    text_content.empty? ? "(No notes content)" : text_content,
    "",
    "---",
    "",
    "*Word Count: #{word_count} words*"
  ].join("\n") + "\n"
end

# Helper method to process notes content
def process_notes_content(notes_html_file, logger)
  word_count = 0
  text_content = ""

  if File.exist?(notes_html_file)
    html_content = File.read(notes_html_file)
    text_content = html_to_plain_text(html_content)

    # Count words
    words = text_content.split(/\s+/)
    word_count = words.length
    logger.info("Calculated word count: #{word_count} words")
  else
    logger.warn("notes.html not found, word count will be 0")
  end

  [text_content, word_count]
end

# Helper method to build complete metadata XML
def build_metadata_xml(meeting_id, events_doc, raw_archive_dir, word_count)
  # Extract timing information
  meeting_start = events_doc.xpath("//event")[0][:timestamp]
  meeting_end = events_doc.xpath("//event").last[:timestamp]

  match = /.*-(\d+)$/.match(meeting_id)
  real_start_time = match[1]
  real_end_time = (real_start_time.to_i + (meeting_end.to_i - meeting_start.to_i)).to_s

  # Build initial XML structure
  builder = Builder::XmlMarkup.new(:indent => 2)
  xml = builder.recording {
    builder.id(meeting_id)
    builder.state("processed")
    builder.published(false)
    builder.start_time(real_start_time)
    builder.end_time(real_end_time)
    builder.participants(BigBlueButton::Events.get_num_participants(events_doc))
    builder.playback
    builder.meta {
      BigBlueButton::Events.get_meeting_metadata("#{raw_archive_dir}/events.xml").each { |k,v|
        builder.method_missing(k, v)
      }
    }
    builder.wordcount(word_count)
  }

  # Parse and append breakout room info if present
  metadata = Nokogiri::XML(xml)
  recording = metadata.root

  [events_doc.xpath("//meeting"),
   events_doc.xpath("//breakout"),
   events_doc.xpath("//breakoutRooms")].each do |nodes|
    recording << nodes if nodes.any?
  end

  # Format with no blanks
  Nokogiri::XML(metadata.to_xml) { |x| x.noblanks }
end

# Parse command line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :default => '58f4a6b3-cd07-444d-8564-59116cb53974', :type => String
end

meeting_id = opts[:meeting_id]

# Load configuration from local config directory for development
script_dir = File.expand_path(File.dirname(__FILE__))
project_root = File.expand_path('../..', script_dir)
props = YAML::load(File.open("#{project_root}/config/bigbluebutton.yml"))
notes_props = YAML::load(File.open("#{project_root}/config/notes.yml"))
format = notes_props['format']

# Set up paths
recording_dir = props['recording_dir']
raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
log_dir = props['log_dir']
note_file = "#{raw_archive_dir}/notes/notes.#{format}"
target_dir = "#{recording_dir}/process/notes/#{meeting_id}"

# Main processing logic
unless FileTest.directory?(target_dir)
  FileUtils.mkdir_p "#{log_dir}/notes"
  logger = Logger.new("#{log_dir}/notes/process-#{meeting_id}.log", 'daily')
  BigBlueButton.logger = logger
  BigBlueButton.logger.info("Processing script notes.rb")
  FileUtils.mkdir_p target_dir

  # Early exit if there are no notes for this meeting
  unless File.exist?(note_file)
    BigBlueButton.logger.info("There wasn't any note for #{meeting_id}")
    File.write("#{recording_dir}/status/processed/#{meeting_id}-notes.done", "Processed #{meeting_id}")
    exit 0
  end

  begin
    # Copy notes file
    FileUtils.cp(note_file, "#{target_dir}/notes.#{format}")

    # Process notes content
    notes_html_file = "#{raw_archive_dir}/notes/notes.html"
    text_content, word_count = process_notes_content(notes_html_file, BigBlueButton.logger)

    # Create notes.md
    BigBlueButton.logger.info("Creating notes.md")
    notes_md_content = build_markdown_content(text_content, word_count)
    File.write("#{target_dir}/notes.md", notes_md_content)
    BigBlueButton.logger.info("Created notes.md with #{word_count} words")

    # Load events.xml and build complete metadata
    events_doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))
    metadata = build_metadata_xml(meeting_id, events_doc, raw_archive_dir, word_count)

    # Write metadata.xml
    File.write("#{target_dir}/metadata.xml", metadata.root)
    BigBlueButton.logger.info("Created metadata.xml with state=processed, timing info, and word count (#{word_count})")

    # Write status file
    File.write("#{recording_dir}/status/processed/#{meeting_id}-notes.done", "Processed #{meeting_id}")

  rescue Exception => e
    BigBlueButton.logger.error(e.message)
    e.backtrace.each do |traceline|
      BigBlueButton.logger.error(traceline)
    end
    exit 1
  end
end
