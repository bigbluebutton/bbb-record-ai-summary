# BigBlueButton AI Playback Development

Local development environment for testing and developing BigBlueButton recording and playback scripts.

## Quick Start

```bash
# Test a recording
./apply.sh <meeting_id>

# Clean generated files
./clean.sh <meeting_id>

# Compare with server output
./compare.sh <meeting_id>
```

## Documentation

- **[QUICK_REFERENCE.md](QUICK_REFERENCE.md)** - Command cheat sheet
- **[TEST_HARNESS.md](TEST_HARNESS.md)** - Complete usage guide
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - BBB recording system details
- **[SUMMARY.md](SUMMARY.md)** - What was built

## Project Structure

```
├── config/          # Local configuration
├── notes/           # Notes playback scripts
├── recording/       # Test workspace
│   ├── raw/        # Input recordings
│   ├── process/    # Processed output
│   ├── publish/    # Published output
│   └── status/     # Status files
├── logs/           # Processing logs
├── apply.sh        # Run test
├── clean.sh        # Clean output
└── compare.sh      # Validate results
```

## Development Workflow

1. **Edit scripts** in `notes/process/` or `notes/publish/`
2. **Clean previous run**: `./clean.sh <meeting_id>`
3. **Test changes**: `./apply.sh <meeting_id>`
4. **Validate**: `./compare.sh <meeting_id>`
5. **Iterate** as needed

See [TEST_HARNESS.md](TEST_HARNESS.md) for details.
