# Auto-loader for all extractor modules
# Requires all files in the extractors directory

Dir[File.join(__dir__, 'extractors', '*.rb')].sort.each { |file| require file }
