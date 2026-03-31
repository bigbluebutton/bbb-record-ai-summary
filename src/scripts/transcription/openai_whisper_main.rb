#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper_main.rb — General-purpose OpenAI Whisper transcription scenario.
#
# The recommended starting point for most meetings. Injects the individual speaker's
# name as a Whisper prompt (anchors the decoder to the right person) and passes all
# participant names as known_speaker_names[] for speaker context. Quality thresholds
# are left at openai_whisper.rb defaults, which work well for typical meeting audio.
#
# For specific environments, prefer a tuned scenario:
#   openai_whisper_precise.rb     — noisy rooms, poor microphones
#   openai_whisper_inclusive.rb   — studio-quality audio, maximum coverage
#   openai_whisper_contextual.rb  — specialised domain vocabulary
#   openai_whisper_multilingual.rb — code-switching or accented speech
#
# Any WHISPER_* or OPENAI_* environment variables set before this script are
# preserved: explicit caller values always win over these scenario defaults.
#

require 'nokogiri'
require_relative 'transcription_utils'

audio_file = ARGV[0]
events_xml = ARGV[2]

if audio_file && events_xml && File.exist?(events_xml)
  events_doc = Nokogiri::XML(File.read(events_xml))

  if ENV['WHISPER_PROMPT'].to_s.strip.empty?
    speaker_name = TranscriptionUtils.speaker_name_for_audio(events_doc, audio_file)
    if speaker_name
      $stderr.puts "INFO : Speaker: #{speaker_name}"
      ENV['WHISPER_PROMPT'] =
        "Meeting participant #{speaker_name} speaking. " \
        "This is their individual microphone audio from a meeting."
    end
  end

  if ENV['WHISPER_KNOWN_SPEAKER_NAMES'].to_s.strip.empty?
    all_names = TranscriptionUtils.all_speaker_names(events_doc)
    unless all_names.empty?
      $stderr.puts "INFO : Known speakers: #{all_names.join(', ')}"
      ENV['WHISPER_KNOWN_SPEAKER_NAMES'] = all_names.join(',')
    end
  end
end

load File.join(__dir__, 'openai_whisper.rb')
