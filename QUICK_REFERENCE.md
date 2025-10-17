# Quick Reference - Test Harness Commands

## Essential Commands

### List Available Recordings
```bash
ls recording/raw/
```

### Run Test (Process + Publish)
```bash
./apply.sh <meeting_id>
```

### Clean Generated Files
```bash
./clean.sh <meeting_id>
```

### Preview Cleanup (Dry Run)
```bash
./clean.sh --dry-run <meeting_id>
```

### Compare with Server
```bash
./compare.sh <meeting_id>
```

## Common Workflows

### Initial Test
```bash
# 1. List available recordings
ls recording/raw/

# 2. Run test
./apply.sh <meeting_id>

# 3. Check results
ls recording/publish/notes/<meeting_id>/
```

### Modify and Retest
```bash
# 1. Clean previous run
./clean.sh <meeting_id>

# 2. Edit scripts
vim notes/process/notes.rb
# OR
vim notes/publish/notes.rb

# 3. Test changes
./apply.sh <meeting_id>

# 4. Check logs if needed
tail logs/notes/process-<meeting_id>.log
tail logs/notes/publish-<meeting_id>.log
```

### Validate Against Server
```bash
# 1. Run test locally
./apply.sh <meeting_id>

# 2. Compare with server
./compare.sh <meeting_id>
```

## File Locations

### Input
```
recording/raw/<meeting_id>/
├── events.xml
├── audio/
├── notes/
│   ├── notes.pdf
│   ├── notes.html
│   └── notes.etherpad
└── ...
```

### Process Output
```
recording/process/notes/<meeting_id>/
├── metadata.xml (state="processed")
└── notes.pdf
```

### Publish Output
```
recording/publish/notes/<meeting_id>/
├── metadata.xml (state="published", with playback link)
└── notes.pdf
```

### Logs
```
logs/notes/
├── process-<meeting_id>.log
└── publish-<meeting_id>.log
```

### Status Files
```
recording/status/
├── processed/<meeting_id>-notes.done
└── published/<meeting_id>-notes.done
```

## Inspection Commands

### View Metadata
```bash
# Process metadata
cat recording/process/notes/<meeting_id>/metadata.xml

# Published metadata
cat recording/publish/notes/<meeting_id>/metadata.xml
```

### Check File Sizes
```bash
# Process output
ls -lh recording/process/notes/<meeting_id>/

# Published output
ls -lh recording/publish/notes/<meeting_id>/
```

### View Logs
```bash
# Recent process log entries
tail -20 logs/notes/process-<meeting_id>.log

# Recent publish log entries
tail -20 logs/notes/publish-<meeting_id>.log

# Follow logs in real-time
tail -f logs/notes/process-<meeting_id>.log
```

### Check Status Files
```bash
# Process status
cat recording/status/processed/<meeting_id>-notes.done

# Publish status
cat recording/status/published/<meeting_id>-notes.done

# List all status files
ls -la recording/status/*/*.done
```

## Troubleshooting

### Script Fails
```bash
# Check logs
cat logs/notes/process-<meeting_id>.log
cat logs/notes/publish-<meeting_id>.log

# Check if raw data exists
ls recording/raw/<meeting_id>/

# Check if notes exist
ls recording/raw/<meeting_id>/notes/
```

### Clean and Retry
```bash
./clean.sh <meeting_id>
./apply.sh <meeting_id>
```

### Verify Directories Exist
```bash
ls -la recording/{process,publish,status}
ls -la logs/notes/
```

## Development Cycle

```
┌─────────────────┐
│  Edit Scripts   │
│ (notes/*.rb)    │
└────────┬────────┘
         ↓
┌─────────────────┐
│  Clean Old Run  │
│ ./clean.sh ID   │
└────────┬────────┘
         ↓
┌─────────────────┐
│   Run Test      │
│ ./apply.sh ID   │
└────────┬────────┘
         ↓
┌─────────────────┐
│  Check Output   │
│  & Logs         │
└────────┬────────┘
         ↓
    ┌────┴────┐
    │  Good?  │
    └─┬────┬──┘
  No  │    │ Yes
      │    ↓
      │  ┌─────────────────┐
      │  │  Compare with   │
      │  │     Server      │
      │  │ ./compare.sh ID │
      │  └─────────────────┘
      │
      └──→ Repeat
```

## Example Session

```bash
# List recordings
$ ls recording/raw/
1b30d71454b880bb108093065a18cb6ea994d81c-1760738236204

# Set recording ID variable for convenience
$ MEETING_ID=1b30d71454b880bb108093065a18cb6ea994d81c-1760738236204

# Initial test
$ ./apply.sh $MEETING_ID
# ✓ Process script completed successfully
# ✓ Publish script completed successfully

# View results
$ ls recording/publish/notes/$MEETING_ID/
metadata.xml  notes.pdf

# Make changes to script
$ vim notes/process/notes.rb

# Clean and retest
$ ./clean.sh $MEETING_ID
$ ./apply.sh $MEETING_ID

# Compare with server
$ ./compare.sh $MEETING_ID
```

## Quick Checks

```bash
# Did process succeed?
test -f recording/status/processed/$MEETING_ID-notes.done && echo "✓ Processed" || echo "✗ Not processed"

# Did publish succeed?
test -f recording/status/published/$MEETING_ID-notes.done && echo "✓ Published" || echo "✗ Not published"

# What files were created?
find recording/process/notes/$MEETING_ID/ recording/publish/notes/$MEETING_ID/ -type f 2>/dev/null
```
