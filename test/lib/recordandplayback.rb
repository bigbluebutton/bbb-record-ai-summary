# frozen_string_literal: true

# Lightweight shim for the BigBlueButton recordandplayback library.
#
# This file implements the subset of the BBB recording library that the
# ai-summary pipeline actually uses.  It allows the scripts to run on a
# machine that does not have BigBlueButton installed.
#
# Place (or symlink) this file at:
#   /usr/local/bigbluebutton/core/lib/recordandplayback.rb
#
# Dependencies: nokogiri (already required by the ai-summary scripts)

require 'nokogiri'
require 'logger'
require 'find'
require 'fileutils'
require 'pp'
require 'set'
require 'shellwords'

module BigBlueButton
  class MissingDirectoryException < RuntimeError; end
  class FileNotFoundException < RuntimeError; end

  # -- Logger ---------------------------------------------------------------

  def self.logger=(log)
    @logger = log
  end

  def self.logger
    return @logger if @logger

    @logger = Logger.new($stdout)
    @logger.level = Logger::INFO
    @logger
  end

  # -- Command execution ----------------------------------------------------

  def self.execute(command, fail_on_error = true)
    BigBlueButton.logger.info("Executing: #{command.respond_to?(:to_ary) ? Shellwords.join(command) : command}")
    IO.popen(command, err: %i[child out]) do |io|
      io.each_line do |line|
        BigBlueButton.logger.info(line.chomp)
      end
    end
    status = $?

    BigBlueButton.logger.info("Success?: #{status.success?}")
    BigBlueButton.logger.info("Process exited? #{status.exited?}")
    BigBlueButton.logger.info("Exit status: #{status.exitstatus}")
    raise 'Execution failed' if status.success? == false && fail_on_error

    status
  end

  def self.exec_ret(*command)
    execute(command, false).exitstatus
  end

  def self.exec_redirect_ret(outio, *command)
    BigBlueButton.logger.info "Executing: #{Shellwords.join(command)}"
    BigBlueButton.logger.info "Sending output to #{outio}"
    IO.pipe do |r, w|
      pid = spawn(*command, out: outio, err: w)
      w.close
      r.each_line do |line|
        BigBlueButton.logger.info line.chomp
      end
      Process.waitpid(pid)
      BigBlueButton.logger.info "Exit status: #{$?.exitstatus}"
      return $?.exitstatus
    end
  end

  # -- Utilities -------------------------------------------------------------

  def self.hash_to_str(hash)
    PP.pp(hash, '')
  end

  def self.monotonic_clock
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).to_i
  end

  def self.record_id_to_timestamp(r)
    r.split('-')[1].to_i / 1000
  end

  def self.done_to_timestamp(r)
    BigBlueButton.record_id_to_timestamp(File.basename(r, '.done'))
  end

  def self.get_dir_size(dir_name)
    size = 0
    if FileTest.directory?(dir_name)
      Find.find(dir_name) { |f| size += File.size(f) }
    end
    size.to_s
  end

  # -- XML helpers -----------------------------------------------------------

  def self.add_tag_to_xml(xml_filename, parent_xpath, tag, content)
    return unless File.exist?(xml_filename)

    doc = Nokogiri::XML(File.read(xml_filename)) { |x| x.noblanks }

    node = doc.at_xpath("#{parent_xpath}/#{tag}")
    node.remove unless node.nil?

    node = Nokogiri::XML::Node.new(tag, doc)
    node.content = content

    doc.at(parent_xpath) << node

    File.write(xml_filename, doc.to_xml(indent: 2))
  end

  def self.add_raw_size_to_metadata(dir_name, raw_dir_name)
    size = BigBlueButton.get_dir_size(raw_dir_name)
    BigBlueButton.add_tag_to_xml("#{dir_name}/metadata.xml", '//recording', 'raw_size', size)
  end

  def self.add_playback_size_to_metadata(dir_name)
    size = BigBlueButton.get_dir_size(dir_name)
    BigBlueButton.add_tag_to_xml("#{dir_name}/metadata.xml", '//recording/playback', 'size', size)
  end

  def self.add_download_size_to_metadata(dir_name)
    size = BigBlueButton.get_dir_size(dir_name)
    BigBlueButton.add_tag_to_xml("#{dir_name}/metadata.xml", '//recording/download', 'size', size)
  end

  # -- File operations -------------------------------------------------------

  def self.download(url, output)
    BigBlueButton.logger.info "Downloading #{url} to #{output}"
    require 'net/http'
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      http.request(request) do |response|
        File.open(output, 'wb') do |io|
          response.read_body { |chunk| io.write(chunk) }
        end
      end
    end
  end

  def self.try_download(url, output)
    download(url, output)
  rescue StandardError => e
    BigBlueButton.logger.error "Failed to download file: #{e}"
    FileUtils.rm_f output
  end

  # -- Config ----------------------------------------------------------------

  def self.rap_core_path
    File.expand_path('../..', __FILE__)
  end

  def self.rap_scripts_path
    File.join(BigBlueButton.rap_core_path, 'scripts')
  end

  def self.read_props
    return @props if @props

    filepath = File.join(BigBlueButton.rap_scripts_path, 'bigbluebutton.yml')
    @props = YAML.safe_load(File.read(filepath))

    override_path = '/etc/bigbluebutton/recording/recording.yml'
    if File.file?(override_path)
      override = YAML.safe_load(File.read(override_path))
      @props = @props.merge(override)
    end
    @props
  end

  # -- Redis (no-op) ---------------------------------------------------------

  def self.redis_publisher=(publisher)
    @redis_publisher = publisher
  end

  def self.redis_publisher
    @redis_publisher
  end

  def self.create_redis_publisher
    # no-op in test harness
  end

  # -- Events module ---------------------------------------------------------

  module Events
    def self.get_num_participants(events)
      participants_ids = Set.new
      events.xpath("/recording/event[@eventname='ParticipantJoinEvent']").each do |join_event|
        user_id = join_event.at_xpath('userId').text
        user_id.gsub!(/_\d*$/, '')
        participants_ids.add(user_id)
      end
      participants_ids.length
    end

    def self.get_meeting_metadata(events_xml)
      BigBlueButton.logger.info('Task: Getting meeting metadata')
      doc = Nokogiri::XML(File.open(events_xml))
      metadata = {}
      doc.xpath('recording/metadata').each do |e|
        e.keys.each do |k|
          metadata[k] = e.attribute(k)
        end
      end
      metadata
    end

    def self.get_external_meeting_id(events_xml)
      BigBlueButton.logger.info('Task: Getting external meeting id')
      metadata = get_meeting_metadata(events_xml)
      metadata['meetingId'] || {}
    end

    def self.first_event_timestamp(events)
      first_event = events.at_xpath('/recording/event[position() = 1]')
      first_event['timestamp'].to_i if first_event && first_event.key?('timestamp')
    end

    def self.last_event_timestamp(events)
      last_event = events.at_xpath('/recording/event[position() = last()]')
      last_event['timestamp'].to_i if last_event && last_event.key?('timestamp')
    end

    def self.get_record_status_events(events_xml)
      BigBlueButton.logger.info 'Getting record status events'
      rec_events = []
      events_xml.xpath("recording/event[@eventname='RecordStatusEvent']").each do |event|
        s = { timestamp: event['timestamp'].to_i }
        rec_events << s
      end
      rec_events.sort_by { |a| a[:timestamp] }
    end

    def self.get_start_and_stop_rec_events(events_xml, allow_empty_events = false)
      BigBlueButton.logger.info 'Getting start and stop rec button events'
      rec_events = BigBlueButton::Events.get_record_status_events(events_xml)
      if !allow_empty_events && rec_events.empty?
        rec_events << { timestamp: BigBlueButton::Events.first_event_timestamp(events_xml) }
      end
      if rec_events.size.odd?
        rec_events << { timestamp: BigBlueButton::Events.last_event_timestamp(events_xml) }
      end
      rec_events.sort_by { |a| a[:timestamp] }
    end

    def self.match_start_and_stop_rec_events(rec_events)
      BigBlueButton.logger.info 'Matching record events'
      matched_rec_events = []
      rec_events.each_with_index do |evt, i|
        if i.even?
          matched_rec_events << {
            start_timestamp: evt[:timestamp],
            stop_timestamp: rec_events[i + 1][:timestamp]
          }
        end
      end
      matched_rec_events
    end

    def self.get_recording_length(events)
      duration = 0
      start_stop_events = BigBlueButton::Events.match_start_and_stop_rec_events(
        BigBlueButton::Events.get_start_and_stop_rec_events(events)
      )
      start_stop_events.each do |start_stop|
        duration += start_stop[:stop_timestamp] - start_stop[:start_timestamp]
      end
      duration
    end
  end
end
