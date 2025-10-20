# Poll results extractor
# Extracts poll questions and results from events.xml

module NotesExtractors
  class PollsExtractor
    def self.extract(events_doc, logger)
      polls = []

      # Extract poll published events
      events_doc.xpath("//event[@eventname='PollPublishedRecordEvent']").each do |event|
        poll_id = event.at_xpath("pollId")&.text
        question = event.at_xpath("question")&.text

        # Parse answers
        answers = []
        event.xpath(".//answer").each do |answer|
          answers << {
            text: answer.at_xpath("key")&.text,
            votes: answer.at_xpath("numVotes")&.text.to_i
          }
        end

        polls << { id: poll_id, question: question, answers: answers } if question
      end

      logger.info("Extracted #{polls.length} polls")
      polls.any? ? polls : nil
    end
  end
end
