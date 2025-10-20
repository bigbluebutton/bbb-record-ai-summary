# Attendees list extractor
# Extracts unique participant names from events.xml

module NotesExtractors
  class AttendeesExtractor
    def self.extract(events_doc, logger)
      attendees = []

      # Get unique participant names from ParticipantJoinEvent
      events_doc.xpath("//event[@eventname='ParticipantJoinEvent']/name").each do |name_node|
        name = name_node.text.strip
        attendees << name unless attendees.include?(name) || name.empty?
      end

      logger.info("Extracted #{attendees.length} attendees")
      attendees.any? ? attendees.sort : nil
    end
  end
end
