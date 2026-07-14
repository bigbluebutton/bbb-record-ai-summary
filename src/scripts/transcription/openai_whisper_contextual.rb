#!/usr/bin/env ruby
# encoding: UTF-8
#
# openai_whisper_contextual.rb — Domain vocabulary and speaker context prompt.
#
# Scenario: meetings with specialised terminology (technical, medical, legal, government)
# where Whisper mis-transcribes domain-specific words with generic phonetic guesses.
# A small temperature increase (0.15) loosens the decoder enough to prefer domain
# vocabulary from the prompt over its default priors, while remaining coherent.
#
# Speaker names are injected the same way as openai_whisper_speaker_aware.rb.
# A domain context string can be prepended to the prompt via the environment variable
# WHISPER_CONTEXT_PROMPT (set before calling this script), or via openai.context_prompt
# in transcription.yml. The speaker-specific sentence is always appended after it.
#
# Example WHISPER_CONTEXT_PROMPT values:
#   "This is a software engineering meeting. Terms: Kubernetes, CI/CD, microservices."
#   "Réunion sur les politiques de santé publique. Vocabulaire: épidémiologie, HAS, DGSS."
#
# Tuned parameters vs openai_whisper.rb defaults:
#   temperature: 0.15  (default: 0.0)
#
# Quality thresholds are left at defaults — combine with precise/inclusive env vars if needed.
#
# Any WHISPER_* or OPENAI_* environment variables set before this script are
# preserved: explicit caller values always win over these scenario defaults.
#

require 'nokogiri'
require 'yaml'
require_relative 'transcription_utils'

audio_file = ARGV[0]
events_xml = ARGV[2]

context_prompt = ENV['WHISPER_CONTEXT_PROMPT'].to_s.strip
if context_prompt.empty?
  yml_path = File.join(__dir__, 'transcription.yml')
  override_path = '/etc/bigbluebutton/post-archive-transcription.yml'
  [yml_path, override_path].each do |path|
    next unless File.exist?(path)
    cfg = YAML.safe_load(File.read(path)) rescue {}
    val = cfg.dig('openai', 'context_prompt').to_s.strip
    unless val.empty?
      context_prompt = val
      break
    end
  end
end

if audio_file && events_xml && File.exist?(events_xml)
  events_doc = Nokogiri::XML(File.read(events_xml))

  if ENV['WHISPER_PROMPT'].to_s.strip.empty?
    parts = []
    parts << context_prompt unless context_prompt.empty?
    # Vocabulary priming: domain terms (context_prompt) plus participant names,
    # not instruction text — Whisper treats the prompt as preceding transcript.
    all_names = TranscriptionUtils.all_speaker_names(events_doc)
    unless all_names.empty?
      $stderr.puts "INFO : Participants: #{all_names.join(', ')}"
      parts << "Meeting participants: #{all_names.join(', ')}."
    end
    ENV['WHISPER_PROMPT'] = parts.join(' ') unless parts.empty?
  end

  if ENV['WHISPER_KNOWN_SPEAKER_NAMES'].to_s.strip.empty?
    all_names = TranscriptionUtils.all_speaker_names(events_doc)
    unless all_names.empty?
      $stderr.puts "INFO : Known speakers: #{all_names.join(', ')}"
      ENV['WHISPER_KNOWN_SPEAKER_NAMES'] = all_names.join(',')
    end
  end
end

ENV['WHISPER_TEMPERATURE'] ||= '0.15'

load File.join(__dir__, 'openai_whisper.rb')
