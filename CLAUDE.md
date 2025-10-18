# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a local development environment for testing BigBlueButton (BBB) recording and playback scripts. It simulates the BBB recording pipeline without requiring a full BBB server installation, allowing rapid iteration on process/publish scripts for recording formats.

## Essential Commands

### Testing Workflow
```bash
# Test a recording (runs process + publish scripts)
./apply.sh <meeting_id>

# Clean generated files before retesting
./clean.sh <meeting_id>

# Preview what clean.sh would delete
./clean.sh --dry-run <meeting_id>

# Compare local output with server output
./compare.sh <meeting_id>
```

### Listing Available Recordings
```bash
ls recording/raw/
```

### Viewing Logs
```bash
tail -f logs/notes/process-<meeting_id>.log
tail -f logs/notes/publish-<meeting_id>.log
```

## Architecture

### BigBlueButton Recording Pipeline

BBB processes recordings through a 6-stage pipeline:
```
Capture → Archive → Sanity → Process → Publish → Playback
```

This test harness focuses on the **Process** and **Publish** stages for the "notes" playback format.

### Process Stage (notes/process/notes.rb)
**Input:** `recording/raw/<meeting_id>/` (raw recording data from BBB)
**Output:** `recording/process/notes/<meeting_id>/`

Key operations:
1. Loads configuration from `config/bigbluebutton.yml` and `config/notes.yml`
2. Checks for `notes.pdf` in raw recording
3. Parses `events.xml` for meeting timing and metadata
4. Calculates word count from `notes.html`
5. Creates `metadata.xml` with state="processed", meeting info, and word count
6. Copies `notes.pdf` to process directory
7. Creates `.done` status file in `recording/status/processed/`

### Publish Stage (notes/publish/notes.rb)
**Input:** `recording/process/notes/<meeting_id>/`
**Output:** `recording/publish/notes/<meeting_id>/`

Key operations:
1. Loads processed metadata and word count
2. Generates new PDF with notes content + word count footer using Prawn
3. Updates `metadata.xml` with state="published" and playback link
4. Adds file size metadata
5. Creates `.done` status file in `recording/status/published/`

### Directory Structure
```
bbb-playback-ai/
├── notes/                      # Notes playback format source code
│   ├── process/notes.rb       # Process stage script
│   └── publish/notes.rb       # Publish stage script
├── config/                     # Local configuration (overrides system paths)
│   ├── bigbluebutton.yml      # Points to ./recording and ./logs
│   └── notes.yml              # Notes format configuration
├── recording/                  # Local recording workspace
│   ├── raw/                   # Input: Raw recordings from BBB server
│   ├── process/notes/         # Output: Processed files
│   ├── publish/notes/         # Output: Published files
│   └── status/                # Status markers (.done/.fail files)
├── logs/notes/                # Processing logs
├── apply.sh                   # Main test harness
├── clean.sh                   # Cleanup script
└── compare.sh                 # Validation tool
```

## Configuration System

The test harness uses **local configuration** in `./config/` that overrides BBB system paths:

- `config/bigbluebutton.yml`: Sets `recording_dir` to `./recording` and `log_dir` to `./logs`
- `config/notes.yml`: Sets `publish_dir` to `./recording/publish/notes`

Both process and publish scripts load configs from `../../config/` relative to their location.

## Development Workflow

1. **Copy raw recording data** (if needed):
   ```bash
   sudo cp -r /var/bigbluebutton/recording/raw/<meeting_id> ./recording/raw/
   ```

2. **Edit scripts**: Modify `notes/process/notes.rb` or `notes/publish/notes.rb`

3. **Clean previous run**: `./clean.sh <meeting_id>`

4. **Test changes**: `./apply.sh <meeting_id>`

5. **Review logs**: Check `logs/notes/` for errors

6. **Compare with server**: `./compare.sh <meeting_id>` to validate

7. **Iterate**: Repeat steps 2-6 as needed

8. **Deploy to production** (when ready):
   ```bash
   sudo cp notes/process/notes.rb /usr/local/bigbluebutton/core/scripts/process/
   sudo cp notes/publish/notes.rb /usr/local/bigbluebutton/core/scripts/publish/
   ```

## Key Implementation Details

### Script Structure Pattern
All BBB process/publish scripts follow this pattern:
```ruby
# 1. Load dependencies
require '/usr/local/bigbluebutton/core/lib/recordandplayback'
require 'optimist'
require 'yaml'

# 2. Parse command-line options
opts = Optimist::options do
  opt :meeting_id, "Meeting id", type: String
end

# 3. Load configuration
props = YAML::load(File.open('path/to/config.yml'))

# 4. Set up directories and logging
logger = Logger.new("#{log_dir}/format/process-#{meeting_id}.log")
BigBlueButton.logger = logger

# 5. Check if already processed (idempotency)
if not FileTest.directory?(target_dir)
  # Do processing work
end

# 6. Error handling
rescue Exception => e
  BigBlueButton.logger.error(e.message)
  exit 1
end
```

### Metadata.xml Evolution
- **Process stage**: Creates metadata.xml with state="processing" → state="processed"
- **Publish stage**: Updates metadata.xml with state="published" and playback links

### Status Files
- `.done` files in `recording/status/processed/` signal process completion
- `.done` files in `recording/status/published/` signal publish completion
- `.fail` files signal errors

### Events.xml
Raw recordings include `events.xml` with all meeting events. Use Nokogiri to parse:
```ruby
@doc = Nokogiri::XML(File.open("#{raw_archive_dir}/events.xml"))
meeting_start = @doc.xpath("//event")[0][:timestamp]
meeting_end = @doc.xpath("//event").last()[:timestamp]
```

## Important Notes

### Test Harness vs Production Differences
- **Cleanup**: Test harness keeps all files; production removes processed files to save space
- **Execution**: Test harness is manual (`./apply.sh`); production uses automated workers
- **Config**: Test harness uses `./config/`; production uses `/usr/local/bigbluebutton/core/scripts/`

### Library Usage
Scripts use the system BBB library:
```ruby
require '/usr/local/bigbluebutton/core/lib/recordandplayback'
```

This provides utilities like:
- `BigBlueButton.logger` - Logging
- `BigBlueButton::Events.get_recording_length(@doc)` - Calculate recording duration
- `BigBlueButton::Events.get_meeting_metadata(path)` - Extract metadata
- `BigBlueButton.add_raw_size_to_metadata(dir, raw_dir)` - Add file sizes
- `BigBlueButton.add_playback_size_to_metadata(dir)` - Add playback sizes

### Meeting ID Format
- Process script receives: `<meeting_id>` (e.g., `1b30d714...-1760738236204`)
- Publish script receives: `<meeting_id>-<format>` (e.g., `1b30d714...-1760738236204-notes`)
- Publish script must parse this format to extract meeting_id

### Word Count Feature
The notes format includes custom word count functionality:
- Process stage calculates words from `notes.html` (strips HTML tags/entities)
- Stores count in `<wordcount>` element in metadata.xml
- Publish stage reads count and adds it to generated PDF footer

## Creating New Recording Formats

To create a new format (e.g., "whisper" for audio transcription):

1. Create directory structure:
   ```bash
   mkdir -p whisper/{process,publish}
   ```

2. Create scripts based on notes format pattern:
   - `whisper/process/whisper.rb` - Process raw recording
   - `whisper/publish/whisper.rb` - Publish processed files

3. Create configuration:
   - `config/whisper.yml` - Format-specific settings

4. Test locally:
   ```bash
   ./apply.sh <meeting_id>
   ```

5. Deploy to production when ready
