#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper_with_prompt.rb — Wrapper around openai_whisper.rb that injects
# a per-track speaker prompt derived from events.xml.
#
# For each audio track, looks up the owning participant via:
#   AudioTrackPublishedEvent/userId → ParticipantJoinEvent/name
# then sets WHISPER_ADDITIONAL_PROMPT_PRE to:
#   "Meeting participant <name> speaking. This is their individual microphone audio from a meeting."
#
# All transcription logic, config loading, and quality metrics are handled by
# openai_whisper.rb. Any WHISPER_* or OPENAI_* environment variables set before
# this script runs are preserved and passed through.
#

require 'nokogiri'

audio_file = ARGV[0]
events_xml = ARGV[2]

if audio_file && events_xml && File.exist?(events_xml)
  audio_basename = File.basename(audio_file.to_s)
  events_doc     = Nokogiri::XML(File.read(events_xml))

  track_user_id = nil
  events_doc.xpath("//event[@eventname='AudioTrackPublishedEvent']").each do |ev|
    if File.basename(ev.at_xpath('filename')&.text.to_s) == audio_basename
      track_user_id = ev.at_xpath('userId')&.text
      break
    end
  end

  if track_user_id
    events_doc.xpath("//event[@eventname='ParticipantJoinEvent']").each do |ev|
      if ev.at_xpath('userId')&.text == track_user_id
        speaker_name = ev.at_xpath('name')&.text&.strip
        if speaker_name && !speaker_name.empty?
          $stderr.puts "INFO : Speaker: #{speaker_name}"
          ENV['WHISPER_PROMPT'] =
            "Meeting participant #{speaker_name} speaking. " \
            "This is their individual microphone audio from a meeting."
        end
        break
      end
    end
  end
end

load File.join(__dir__, 'openai_whisper.rb')
