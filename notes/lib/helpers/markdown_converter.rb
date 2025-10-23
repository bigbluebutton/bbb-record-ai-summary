# Simple Markdown to HTML converter
# Converts basic markdown syntax to HTML for display in notes.html

module MarkdownConverter
  # Convert markdown text to HTML
  def self.convert(markdown_text)
    return '' if markdown_text.nil? || markdown_text.empty?

    html = markdown_text.dup

    # Escape HTML entities first
    html = escape_html(html)

    # Convert headers (must be done before other formatting)
    html = html.gsub(/^### (.+)$/m, '<h3>\1</h3>')
    html = html.gsub(/^## (.+)$/m, '<h2>\1</h2>')
    html = html.gsub(/^# (.+)$/m, '<h1>\1</h1>')

    # Convert horizontal rules
    html = html.gsub(/^---+$/, '<hr>')
    html = html.gsub(/^\*\*\*+$/, '<hr>')

    # Convert bold and italic (must be done before lists)
    html = html.gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
    html = html.gsub(/__(.+?)__/, '<strong>\1</strong>')
    html = html.gsub(/\*(.+?)\*/, '<em>\1</em>')
    html = html.gsub(/_(.+?)_/, '<em>\1</em>')

    # Convert inline code
    html = html.gsub(/`(.+?)`/, '<code>\1</code>')

    # Convert links
    html = html.gsub(/\[([^\]]+)\]\(([^)]+)\)/, '<a href="\2">\1</a>')

    # Convert lists (unordered)
    html = convert_unordered_lists(html)

    # Convert lists (ordered)
    html = convert_ordered_lists(html)

    # Convert paragraphs (double newlines to <p> tags)
    html = convert_paragraphs(html)

    html
  end

  private

  def self.escape_html(text)
    text.gsub('&', '&amp;')
        .gsub('<', '&lt;')
        .gsub('>', '&gt;')
        .gsub('"', '&quot;')
        .gsub("'", '&#39;')
  end

  def self.convert_unordered_lists(html)
    lines = html.lines
    result = []
    in_list = false

    lines.each do |line|
      # Check for unordered list item (starts with -, *, or +)
      if line.match?(/^\s*[-*+]\s+(.+)/)
        unless in_list
          result << '<ul>'
          in_list = true
        end
        content = line.sub(/^\s*[-*+]\s+/, '').strip
        result << "<li>#{content}</li>"
      else
        if in_list
          result << '</ul>'
          in_list = false
        end
        result << line
      end
    end

    # Close list if still open
    result << '</ul>' if in_list

    result.join
  end

  def self.convert_ordered_lists(html)
    lines = html.lines
    result = []
    in_list = false

    lines.each do |line|
      # Check for ordered list item (starts with number followed by . or ))
      if line.match?(/^\s*\d+\.\s+(.+)/)
        unless in_list
          result << '<ol>'
          in_list = true
        end
        content = line.sub(/^\s*\d+\.\s+/, '').strip
        result << "<li>#{content}</li>"
      else
        if in_list
          result << '</ol>'
          in_list = false
        end
        result << line
      end
    end

    # Close list if still open
    result << '</ol>' if in_list

    result.join
  end

  def self.convert_paragraphs(html)
    # Split on double newlines to identify paragraph blocks
    blocks = html.split(/\n\n+/)

    blocks.map do |block|
      block = block.strip
      next block if block.empty?

      # Don't wrap if already HTML tags
      if block.start_with?('<h1>', '<h2>', '<h3>', '<ul>', '<ol>', '<hr>', '<pre>', '<blockquote>')
        block
      else
        # Check if entire block is just a list or header tag
        if block.match?(/^<(li|h\d|hr|ul|ol)/)
          block
        else
          # Wrap in paragraph tags, preserving internal newlines as <br>
          lines = block.split("\n")
          if lines.length > 1
            "<p>#{lines.join('<br>')}</p>"
          else
            "<p>#{block}</p>"
          end
        end
      end
    end.join("\n")
  end
end
