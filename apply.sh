#!/bin/bash
# BigBlueButton Notes Recording Test Harness
# This script mimics the BBB recording workflow for local development

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if meeting ID is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: Meeting ID required${NC}"
    echo "Usage: $0 <meeting_id>"
    echo ""
    echo "Available recordings:"
    ls -1 recording/raw/ 2>/dev/null || echo "  No recordings found in recording/raw/"
    exit 1
fi

MEETING_ID="$1"
RAW_DIR="recording/raw/${MEETING_ID}"

# Validate meeting ID exists
if [ ! -d "$RAW_DIR" ]; then
    echo -e "${RED}Error: Recording not found: ${RAW_DIR}${NC}"
    echo ""
    echo "Available recordings:"
    ls -1 recording/raw/ 2>/dev/null || echo "  No recordings found"
    exit 1
fi

echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  BigBlueButton Notes Recording Test Harness             ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Meeting ID: ${MEETING_ID}"
echo "Raw Directory: ${RAW_DIR}"
echo ""

# Check if notes exist
if [ ! -f "${RAW_DIR}/notes/notes.pdf" ]; then
    echo -e "${YELLOW}Warning: No notes.pdf found in ${RAW_DIR}/notes/${NC}"
    echo "This recording may not have shared notes."
    echo ""
fi

# Create necessary directories
echo -e "${YELLOW}[1/5]${NC} Creating directory structure..."
mkdir -p recording/process/notes
mkdir -p recording/publish/notes
mkdir -p recording/status/processed
mkdir -p recording/status/published
mkdir -p logs/notes
echo "  ✓ Directories created"
echo ""

# Clean up any previous run for this meeting
echo -e "${YELLOW}[2/5]${NC} Cleaning up previous run (if any)..."
rm -rf "recording/process/notes/${MEETING_ID}" 2>/dev/null || true
rm -rf "recording/publish/notes/${MEETING_ID}" 2>/dev/null || true
rm -f "recording/status/processed/${MEETING_ID}-notes.done" 2>/dev/null || true
rm -f "recording/status/published/${MEETING_ID}-notes.done" 2>/dev/null || true
rm -f "recording/status/published/${MEETING_ID}-notes.fail" 2>/dev/null || true
echo "  ✓ Cleanup complete"
echo ""

# Run process script
echo -e "${YELLOW}[3/5]${NC} Running process script..."
echo "  Command: ruby notes/process/notes.rb -m ${MEETING_ID}"
echo ""

if ruby notes/process/notes.rb -m "${MEETING_ID}"; then
    echo ""
    echo -e "  ${GREEN}✓ Process script completed successfully${NC}"

    # Check for .done file
    if [ -f "recording/status/processed/${MEETING_ID}-notes.done" ]; then
        echo -e "  ${GREEN}✓ Status file created: recording/status/processed/${MEETING_ID}-notes.done${NC}"
    else
        echo -e "  ${RED}✗ Warning: Status file not found${NC}"
    fi

    # Check for processed files
    if [ -d "recording/process/notes/${MEETING_ID}" ]; then
        echo -e "  ${GREEN}✓ Processed files created${NC}"
        echo "    Files:"
        ls -lh "recording/process/notes/${MEETING_ID}/" | tail -n +2 | awk '{print "      - " $9 " (" $5 ")"}'
    fi
else
    echo ""
    echo -e "  ${RED}✗ Process script failed${NC}"
    echo "  Check log: logs/notes/process-${MEETING_ID}.log"
    exit 1
fi
echo ""

# Run publish script
echo -e "${YELLOW}[4/5]${NC} Running publish script..."
echo "  Command: ruby notes/publish/notes.rb -m ${MEETING_ID}-notes"
echo ""

if ruby notes/publish/notes.rb -m "${MEETING_ID}-notes"; then
    echo ""
    echo -e "  ${GREEN}✓ Publish script completed successfully${NC}"

    # Check for .done file
    if [ -f "recording/status/published/${MEETING_ID}-notes.done" ]; then
        echo -e "  ${GREEN}✓ Status file created: recording/status/published/${MEETING_ID}-notes.done${NC}"
    else
        echo -e "  ${RED}✗ Warning: Status file not found${NC}"
    fi

    # Check for published files
    if [ -d "recording/publish/notes/${MEETING_ID}" ]; then
        echo -e "  ${GREEN}✓ Published files created${NC}"
        echo "    Files:"
        ls -lh "recording/publish/notes/${MEETING_ID}/" | tail -n +2 | awk '{print "      - " $9 " (" $5 ")"}'
    fi
else
    echo ""
    echo -e "  ${RED}✗ Publish script failed${NC}"
    echo "  Check log: logs/notes/publish-${MEETING_ID}.log"

    # Check for .fail file
    if [ -f "recording/status/published/${MEETING_ID}-notes.fail" ]; then
        echo -e "  ${RED}✗ Failure status file created${NC}"
    fi
    exit 1
fi
echo ""

# Summary
echo -e "${YELLOW}[5/5]${NC} Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Recording processing completed successfully!${NC}"
echo ""
echo "Output locations:"
echo "  • Processed: recording/process/notes/${MEETING_ID}/"
echo "  • Published: recording/publish/notes/${MEETING_ID}/"
echo "  • Logs:      logs/notes/"
echo ""
echo "Status files:"
echo "  • Processed: recording/status/processed/${MEETING_ID}-notes.done"
echo "  • Published: recording/status/published/${MEETING_ID}-notes.done"
echo ""
echo -e "Run ${YELLOW}./compare.sh ${MEETING_ID}${NC} to compare with server output"
echo ""
