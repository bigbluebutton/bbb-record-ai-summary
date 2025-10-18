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

performance_start = Time.now

# For PRODUCTION - Use system library
require '/usr/local/bigbluebutton/core/lib/recordandplayback'
require 'rubygems'
require 'optimist'
require 'yaml'
require 'builder'
require 'fastimage' # require fastimage to get the image size of the slides (gem install fastimage)

# Load configuration from local config directory for development
script_dir = File.expand_path(File.dirname(__FILE__))
project_root = File.expand_path('../..', script_dir)
bbb_props = YAML::load(File.open("#{project_root}/config/bigbluebutton.yml"))
notes_props = YAML::load(File.open("#{project_root}/config/notes.yml"))

opts = Optimist::options do
  opt :meeting_id, "Meeting id to archive", :default => '58f4a6b3-cd07-444d-8564-59116cb53974', :type => String
end

meeting_id = opts[:meeting_id]
puts meeting_id
match = /(.*)-(.*)/.match meeting_id
meeting_id = match[1]
playback = match[2]

puts meeting_id
puts playback

begin

  if (playback == "notes")

    log_dir = bbb_props['log_dir']

    logger = Logger.new("#{log_dir}/notes/publish-#{meeting_id}.log", 'daily' )
    BigBlueButton.logger = logger

    recording_dir = bbb_props['recording_dir']
    raw_archive_dir = "#{recording_dir}/raw/#{meeting_id}"
    process_dir = "#{recording_dir}/process/notes/#{meeting_id}"
    publish_dir = notes_props['publish_dir']
    format = notes_props['format']
    playback_protocol = bbb_props['playback_protocol']
    playback_host = bbb_props['playback_host']
    target_dir = "#{recording_dir}/publish/notes/#{meeting_id}"
    note_file = "#{process_dir}/notes.#{format}"

    if not FileTest.directory?(target_dir)
      BigBlueButton.logger.info("Making dir target_dir")
      FileUtils.mkdir_p target_dir

      if File.exist? note_file
        BigBlueButton.logger.info("Original notes file: #{note_file}")

        # Convert notes.md to PDF using pandoc
        source_md = "#{process_dir}/notes.md"
        output_pdf = "#{target_dir}/notes.pdf"

        if File.exist?(source_md)
          BigBlueButton.logger.info("Converting notes.md to PDF with pandoc")
          BigBlueButton.logger.info("Source: #{source_md}")
          BigBlueButton.logger.info("Output: #{output_pdf}")

          # Convert markdown to PDF using pandoc
          pandoc_cmd = "pandoc '#{source_md}' -o '#{output_pdf}' --pdf-engine=pdflatex 2>&1"
          result = `#{pandoc_cmd}`

          if $?.success? && File.exist?(output_pdf)
            BigBlueButton.logger.info("Successfully generated PDF from markdown using pandoc")
            BigBlueButton.logger.info("PDF size: #{File.size(output_pdf)} bytes")

            # Also copy the markdown file to publish directory
            FileUtils.cp(source_md, "#{target_dir}/notes.md")
            BigBlueButton.logger.info("Copied notes.md to publish directory")
          else
            BigBlueButton.logger.error("Pandoc conversion failed: #{result}")
            BigBlueButton.logger.warn("Falling back to original PDF")
            FileUtils.cp(note_file, target_dir)
          end
        else
          BigBlueButton.logger.warn("notes.md not found at #{source_md}, using original PDF")
          FileUtils.cp(note_file, target_dir)
        end

        @doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))
        recording_time = BigBlueButton::Events.get_recording_length(@doc)

        BigBlueButton.logger.info("Creating metadata.xml")

        #### INSTEAD OF CREATING THE WHOLE metadata.xml FILE AGAIN, ONLY ADD <playback>
        # Copy metadata.xml from process_dir
        FileUtils.cp("#{process_dir}/metadata.xml", target_dir)
        BigBlueButton.logger.info("Copied metadata.xml file")

        # Update state and add playback to metadata.xml
        ## Load metadata.xml
        metadata = Nokogiri::XML(File.open("#{target_dir}/metadata.xml"))
        ## Update state
        recording = metadata.root
        state = recording.at_xpath("state")
        state.content = "published"
        published = recording.at_xpath("published")
        published.content = "true"
        ## Remove empty playback
        metadata.search('//recording/playback').each do |playback|
          playback.remove
        end
        ## Add the actual playback
        metadata_with_playback = Nokogiri::XML::Builder.with(metadata.at('recording')) do |xml|
          xml.playback {
            xml.format("notes")
            xml.link("#{playback_protocol}://#{playback_host}/notes/#{meeting_id}/notes.#{format}")
            xml.duration("#{recording_time}")
          }
        end
        ## Write the new metadata.xml
        metadata_file = File.new("#{target_dir}/metadata.xml","w")
        metadata = Nokogiri::XML(metadata.to_xml) { |x| x.noblanks }
        metadata_file.write(metadata.root)
        metadata_file.close
        BigBlueButton.logger.info("Added playback to metadata.xml")

        # Now publish this recording files by copying them into the publish folder.
        if not FileTest.directory?(publish_dir)
          FileUtils.mkdir_p publish_dir
        end

        # Get raw size of recording files
        raw_dir = "#{recording_dir}/raw/#{meeting_id}"
        # After all the processing we'll add the published format and raw sizes to the metadata file
        BigBlueButton.add_raw_size_to_metadata(target_dir, raw_dir)
        BigBlueButton.add_playback_size_to_metadata(target_dir)

        # Only copy if target_dir is not already inside publish_dir
        final_publish_dir = "#{publish_dir}/#{meeting_id}"
        if target_dir != final_publish_dir
          FileUtils.cp_r(target_dir, publish_dir) # Copy all the files.
          BigBlueButton.logger.info("Copied files to #{publish_dir}")
        else
          BigBlueButton.logger.info("Files already in publish location: #{target_dir}")
        end
        BigBlueButton.logger.info("Finished publishing script notes.rb successfully.")
      else
        BigBlueButton.logger.info("There wasn't any note for #{meeting_id}")
      end

      # For development, keep the processed files for comparison
      # In production BigBlueButton removes these to save space
      # BigBlueButton.logger.info("Removing processed files.")
      # FileUtils.rm_r(process_dir)

      # Don't remove target_dir in local development - we need it for comparison
      # BigBlueButton.logger.info("Removing published files.")
      # FileUtils.rm_r(target_dir)

      publish_done = File.new("#{recording_dir}/status/published/#{meeting_id}-notes.done", "w")
      publish_done.write("Published #{meeting_id}")
      publish_done.close

    else
      BigBlueButton.logger.info("#{target_dir} is already there")
    end
  end


rescue Exception => e
  BigBlueButton.logger.error(e.message)
  e.backtrace.each do |traceline|
    BigBlueButton.logger.error(traceline)
  end
  publish_done = File.new("#{recording_dir}/status/published/#{meeting_id}-notes.fail", "w")
  publish_done.write("Failed Publishing #{meeting_id}")
  publish_done.close

  exit 1
end
