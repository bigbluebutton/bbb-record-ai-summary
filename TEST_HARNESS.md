# BigBlueButton Record & Playback Test Harness

This directory contains a local development environment for testing BigBlueButton recording scripts without needing to run the full BBB server infrastructure.

## Directory Structure

```
bbb-playback-ai/
├── notes/                   # Source code for notes playback format
│   ├── process/
│   │   └── notes.rb        # Process script
│   ├── publish/
│   │   └── notes.rb        # Publish script
│   └── notes.yml           # Format configuration
├── config/                  # Local configuration files
│   ├── bigbluebutton.yml   # Main BBB config (pointing to ./recording)
│   └── notes.yml           # Notes format config (local paths)
├── recording/              # Local recording workspace (mimics /var/bigbluebutton/recording)
│   ├── raw/                # Raw recording data
│   ├── process/            # Processed output
│   ├── publish/            # Published output
│   └── status/             # Status files (.done/.fail)
├── logs/                   # Processing logs
├── apply.sh                # Main test harness script
├── compare.sh              # Compare local vs server output
└── ARCHITECTURE.md         # System architecture documentation
```

## Prerequisites

### Ruby Gems

The following gems are required (already installed on this system):

```bash
sudo gem install redis builder nokogiri optimist fastimage open4 loofah rubyzip absolute_time journald-logger
```

### System Packages

```bash
sudo apt-get install -y ruby-dev libsystemd-dev
```

## Usage

### 1. Running the Test Harness

Process a recording using the local development environment:

```bash
./apply.sh <meeting_id>
```

Example:
```bash
./apply.sh 1b30d71454b880bb108093065a18cb6ea994d81c-1760738236204
```

The script will:
1. Create necessary directories
2. Run the **process** script (`notes/process/notes.rb`)
3. Run the **publish** script (`notes/publish/notes.rb`)
4. Create `.done` status files
5. Show summary of results

### 2. Comparing Results

Compare the local output with BigBlueButton server output:

```bash
./compare.sh <meeting_id>
```

This will show:
- Directory structure comparison
- Status files comparison
- metadata.xml field comparison
- File size comparison

## How It Works

### Configuration Override

The test harness uses local configuration files in `./config/` that override the system paths:

**config/bigbluebutton.yml:**
- `recording_dir`: Points to `./recording` instead of `/var/bigbluebutton/recording`
- `log_dir`: Points to `./logs` instead of `/var/log/bigbluebutton`

**config/notes.yml:**
- `publish_dir`: Points to `./recording/publish/notes`

### Script Modifications

Both `notes/process/notes.rb` and `notes/publish/notes.rb` have been modified to:

1. Load configs from `../../config/` instead of system locations
2. Use system library: `require '/usr/local/bigbluebutton/core/lib/recordandplayback'`
3. Skip cleanup operations (commented out `FileUtils.rm_r` calls) to preserve files for inspection

### Workflow Simulation

The `apply.sh` script mimics the BigBlueButton recording workflow:

```
Raw Recording → Process → Publish
                   ↓          ↓
              .done file  .done file
```

1. **Process Stage:**
   - Input: `recording/raw/<meeting_id>/`
   - Output: `recording/process/notes/<meeting_id>/`
   - Status: `recording/status/processed/<meeting_id>-notes.done`

2. **Publish Stage:**
   - Input: `recording/process/notes/<meeting_id>/`
   - Output: `recording/publish/notes/<meeting_id>/`
   - Status: `recording/status/published/<meeting_id>-notes.done`

## Development Workflow

### 1. Copy Raw Recording Data

```bash
sudo cp -r /var/bigbluebutton/recording/raw/<meeting_id> ./recording/raw/
```

### 2. Modify Scripts

Edit the scripts in `./notes/process/` or `./notes/publish/`:

```bash
vim notes/process/notes.rb
# OR
vim notes/publish/notes.rb
```

### 3. Test Changes

```bash
./apply.sh <meeting_id>
```

### 4. Review Logs

```bash
tail -f logs/notes/process-<meeting_id>.log
tail -f logs/notes/publish-<meeting_id>.log
```

### 5. Compare with Server

```bash
./compare.sh <meeting_id>
```

### 6. Deploy to Server

Once testing is complete, copy modified scripts to the system:

```bash
sudo cp notes/process/notes.rb /usr/local/bigbluebutton/core/scripts/process/
sudo cp notes/publish/notes.rb /usr/local/bigbluebutton/core/scripts/publish/
sudo cp notes/notes.yml /usr/local/bigbluebutton/core/scripts/
```

## Output Files

### Process Stage Output

`recording/process/notes/<meeting_id>/`:
- `metadata.xml` - Meeting metadata with timing info, state="processed"
- `notes.pdf` - Copy of shared notes PDF from raw recording

### Publish Stage Output

`recording/publish/notes/<meeting_id>/`:
- `metadata.xml` - Updated metadata with playback links, state="published"
- `notes.pdf` - Final published PDF file

### Status Files

- `recording/status/processed/<meeting_id>-notes.done` - Process completion marker
- `recording/status/published/<meeting_id>-notes.done` - Publish completion marker
- `recording/status/published/<meeting_id>-notes.fail` - Publish failure marker (if error)

## Troubleshooting

### Script Fails with Missing Gem

```bash
sudo gem install <gem_name>
```

### Permission Denied Errors

Ensure you have write access to the `./recording` and `./logs` directories:

```bash
chmod -R u+w recording/ logs/
```

### Process Script Fails

Check the log file:

```bash
cat logs/notes/process-<meeting_id>.log
```

### Publish Script Fails

Check the log file:

```bash
cat logs/notes/publish-<meeting_id>.log
```

### No Notes in Recording

The process script will exit early with:

```
There wasn't any note for <meeting_id>
```

This is expected if the recording didn't have shared notes enabled.

## Key Differences from Production

| Aspect | Production BBB | Test Harness |
|--------|---------------|--------------|
| Config location | `/usr/local/bigbluebutton/core/scripts/` | `./config/` |
| Recording dir | `/var/bigbluebutton/recording/` | `./recording/` |
| Log dir | `/var/log/bigbluebutton/` | `./logs/` |
| Cleanup | Removes processed files | Keeps all files for inspection |
| Execution | Automated via workers | Manual via `./apply.sh` |

## Next Steps

For creating a new recording format (e.g., "whisper"), follow the pattern:

1. Create `whisper/process/whisper.rb` and `whisper/publish/whisper.rb`
2. Create `config/whisper.yml`
3. Update `config/bigbluebutton.yml` to include whisper in the steps
4. Test with `./apply.sh`
5. Compare output with `./compare.sh`

See `ARCHITECTURE.md` for detailed information on the BBB record & playback system.
