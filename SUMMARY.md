# Test Harness Setup Summary

## What Was Built

A complete local development environment for testing BigBlueButton recording and playback scripts without requiring the full BBB server infrastructure.

## Components Created

### 1. Configuration Files

**`config/bigbluebutton.yml`**
- Overrides system paths to point to `./recording` and `./logs`
- Maintains compatibility with BBB library expectations
- Allows independent testing without affecting production

**`config/notes.yml`**
- Local publish directory configuration
- PDF format specification

### 2. Modified Scripts

**`notes/process/notes.rb`**
- Modified to load local configs from `../../config/`
- Uses system BBB library (`/usr/local/bigbluebutton/core/lib/recordandplayback`)
- Outputs to `./recording/process/notes/`

**`notes/publish/notes.rb`**
- Modified to load local configs
- Handles local directory structure
- Skips cleanup (keeps files for inspection)
- Outputs to `./recording/publish/notes/`

### 3. Test Harness Scripts

**`apply.sh`** - Main test harness
- Takes meeting ID as argument
- Creates directory structure
- Runs process script
- Runs publish script
- Reports results with color-coded output
- Validates status files and output

**`compare.sh`** - Validation tool
- Compares local output vs server output
- Shows directory structure differences
- Compares metadata.xml fields
- Checks status files
- Reports file sizes

### 4. Directory Structure

```
recording/
├── raw/                    # Input: Raw recording data
├── process/notes/          # Output: Processed files
├── publish/notes/          # Output: Published files
└── status/
    ├── processed/          # Process completion markers
    └── published/          # Publish completion markers

logs/notes/                 # Processing logs
```

### 5. Documentation

- **ARCHITECTURE.md** - Complete BBB record & playback system documentation
- **TEST_HARNESS.md** - Usage guide for the test harness
- **SUMMARY.md** - This file

## How It Works

### Process Flow

```
1. User runs: ./apply.sh <meeting_id>
   │
   ├─> Validates meeting ID exists in ./recording/raw/
   │
   ├─> Creates directory structure
   │   └─> recording/{process,publish,status}
   │
   ├─> Runs: ruby notes/process/notes.rb -m <meeting_id>
   │   │
   │   ├─> Loads config from ./config/bigbluebutton.yml
   │   ├─> Reads raw recording from ./recording/raw/<meeting_id>/
   │   ├─> Extracts notes.pdf
   │   ├─> Parses events.xml for timing
   │   ├─> Creates metadata.xml with meeting info
   │   ├─> Outputs to ./recording/process/notes/<meeting_id>/
   │   └─> Creates .done file in ./recording/status/processed/
   │
   └─> Runs: ruby notes/publish/notes.rb -m <meeting_id>-notes
       │
       ├─> Loads config from ./config/notes.yml
       ├─> Reads from ./recording/process/notes/<meeting_id>/
       ├─> Calculates recording duration
       ├─> Updates metadata.xml with playback link
       ├─> Adds file size metadata
       ├─> Outputs to ./recording/publish/notes/<meeting_id>/
       └─> Creates .done file in ./recording/status/published/

2. User runs: ./compare.sh <meeting_id>
   │
   └─> Compares ./recording/* with /var/bigbluebutton/*
       ├─> Directory structure
       ├─> Status files
       ├─> metadata.xml content
       └─> File sizes
```

### Key Features

1. **Self-Contained**: Works entirely within `./recording` directory
2. **Non-Destructive**: Doesn't modify system BBB installation
3. **Preserves Files**: Keeps all output for inspection
4. **Visual Feedback**: Color-coded output shows progress
5. **Validation**: Compare script verifies correctness
6. **Logging**: Full logs in `./logs/notes/`

## Testing Results

Successfully tested with recording: `1b30d71454b880bb108093065a18cb6ea994d81c-1760738236204`

**Process Stage:**
- ✅ metadata.xml created (588 bytes)
- ✅ notes.pdf copied (15K)
- ✅ Status file created

**Publish Stage:**
- ✅ metadata.xml updated with playback info (852 bytes)
- ✅ notes.pdf published (15K)
- ✅ Status file created

## Dependencies Installed

```bash
# Ruby gems
redis, builder, nokogiri, optimist, fastimage, open4
loofah, rubyzip, absolute_time, journald-logger

# System packages
ruby-dev, libsystemd-dev
```

## Usage Examples

### Test a Recording

```bash
./apply.sh 1b30d71454b880bb108093065a18cb6ea994d81c-1760738236204
```

### Compare with Server

```bash
./compare.sh 1b30d71454b880bb108093065a18cb6ea994d81c-1760738236204
```

### View Logs

```bash
tail -f logs/notes/process-<meeting_id>.log
tail -f logs/notes/publish-<meeting_id>.log
```

### Inspect Output

```bash
ls -lh recording/process/notes/<meeting_id>/
ls -lh recording/publish/notes/<meeting_id>/
cat recording/publish/notes/<meeting_id>/metadata.xml
```

## Next Steps for Development

### To Modify Existing Scripts

1. Edit `notes/process/notes.rb` or `notes/publish/notes.rb`
2. Run `./apply.sh <meeting_id>` to test
3. Check logs if errors occur
4. Use `./compare.sh <meeting_id>` to validate

### To Create New Format (e.g., "whisper")

1. Create directory structure:
   ```bash
   mkdir -p whisper/{process,publish}
   ```

2. Create scripts:
   - `whisper/process/whisper.rb` - Audio transcription with Whisper
   - `whisper/publish/whisper.rb` - Combine notes + transcript → PDF

3. Create config:
   - `config/whisper.yml` - Format-specific settings

4. Update workflow:
   - Edit `config/bigbluebutton.yml` to add whisper to steps

5. Test:
   ```bash
   ./apply.sh <meeting_id>
   ```

### To Deploy to Production

```bash
# Copy modified scripts to system
sudo cp notes/process/notes.rb /usr/local/bigbluebutton/core/scripts/process/
sudo cp notes/publish/notes.rb /usr/local/bigbluebutton/core/scripts/publish/
sudo cp notes/notes.yml /usr/local/bigbluebutton/core/scripts/

# Restart BBB recording workers
sudo systemctl restart bbb-rap-*
```

## Comparison with BigBlueButton Server

| Feature | Test Harness | Production BBB |
|---------|--------------|----------------|
| **Execution** | Manual via `./apply.sh` | Automatic via workers |
| **Location** | `./recording/` | `/var/bigbluebutton/recording/` |
| **Cleanup** | Keeps all files | Removes processed files |
| **Config** | `./config/` | `/usr/local/bigbluebutton/core/scripts/` |
| **Logs** | `./logs/` | `/var/log/bigbluebutton/` |
| **Testing** | Isolated environment | Live system |
| **Validation** | `compare.sh` available | Manual inspection only |

## Benefits

1. **Faster Development**: Test changes without running full BBB server
2. **Safe Testing**: Won't affect production recordings
3. **Easy Debugging**: All files preserved, detailed logs
4. **Quick Iteration**: Modify, test, repeat in seconds
5. **Validation**: Built-in comparison with server output
6. **Documentation**: Clear understanding of BBB recording system

## Files Modified vs Original

Only the following files were created/modified for local development:

- `config/bigbluebutton.yml` - Created (local paths)
- `config/notes.yml` - Created (local paths)
- `notes/process/notes.rb` - Modified (config loading)
- `notes/publish/notes.rb` - Modified (config loading, cleanup disabled)
- `apply.sh` - Created (test harness)
- `compare.sh` - Created (validation)
- Documentation files - Created

**Original BBB installation remains unchanged.**
