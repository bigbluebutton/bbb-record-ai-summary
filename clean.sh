#!/bin/bash
# BigBlueButton Notes Recording Cleanup Script
# Removes all generated files for a recording, preserving raw data

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Parse options
DRY_RUN=false
if [ "$1" = "--dry-run" ] || [ "$1" = "-n" ]; then
    DRY_RUN=true
    shift
fi

# Check if meeting ID is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: Meeting ID required${NC}"
    echo "Usage: $0 [--dry-run] <meeting_id>"
    echo ""
    echo "Options:"
    echo "  --dry-run, -n    Show what would be deleted without actually deleting"
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

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  DRY RUN - No files will be deleted                     ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
else
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  BigBlueButton Recording Cleanup                        ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo "Meeting ID: ${MEETING_ID}"
echo "Raw Directory: ${RAW_DIR} (will be preserved)"
echo ""

# Function to remove directory if it exists
remove_dir() {
    local dir=$1
    local description=$2

    if [ -d "$dir" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}  [DRY RUN] Would remove:${NC} $dir"
            if [ -n "$(ls -A $dir 2>/dev/null)" ]; then
                echo "    Files:"
                ls -lh "$dir" | tail -n +2 | awk '{print "      - " $9 " (" $5 ")"}'
            fi
        else
            echo -e "${BLUE}  Removing:${NC} $dir"
            if [ -n "$(ls -A $dir 2>/dev/null)" ]; then
                echo "    Files:"
                ls -lh "$dir" | tail -n +2 | awk '{print "      - " $9 " (" $5 ")"}'
            fi
            rm -rf "$dir"
            echo -e "    ${GREEN}✓ Removed${NC}"
        fi
    else
        echo -e "${YELLOW}  Not found:${NC} $dir"
    fi
}

# Function to remove file if it exists
remove_file() {
    local file=$1
    local description=$2

    if [ -f "$file" ]; then
        if [ "$DRY_RUN" = true ]; then
            echo -e "${YELLOW}  [DRY RUN] Would remove:${NC} $file"
        else
            echo -e "${BLUE}  Removing:${NC} $file"
            rm -f "$file"
            echo -e "    ${GREEN}✓ Removed${NC}"
        fi
    else
        echo -e "${YELLOW}  Not found:${NC} $file"
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}[1/4]${NC} Cleaning Process Directory"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
remove_dir "recording/process/notes/${MEETING_ID}" "Processed files"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}[2/4]${NC} Cleaning Publish Directory"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
remove_dir "recording/publish/notes/${MEETING_ID}" "Published files"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}[3/4]${NC} Cleaning Log Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
remove_file "logs/notes/process-${MEETING_ID}.log" "Process log"
remove_file "logs/notes/publish-${MEETING_ID}.log" "Publish log"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}[4/4]${NC} Cleaning Status Files"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
remove_file "recording/status/processed/${MEETING_ID}-notes.done" "Process status"
remove_file "recording/status/published/${MEETING_ID}-notes.done" "Publish status"
remove_file "recording/status/published/${MEETING_ID}-notes.fail" "Publish failure status"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}Summary${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}✓ Dry run completed - no files were deleted${NC}"
    echo ""
    echo "To actually delete these files, run:"
    echo -e "  ${GREEN}./clean.sh ${MEETING_ID}${NC}"
else
    echo -e "${GREEN}✓ Cleanup completed successfully!${NC}"
    echo ""
    echo -e "${BLUE}Preserved:${NC}"
    echo "  • Raw recording: ${RAW_DIR}"
    echo ""
    echo -e "${BLUE}Removed:${NC}"
    echo "  • Processed files"
    echo "  • Published files"
    echo "  • Log files"
    echo "  • Status files"
    echo ""
    echo "The recording is now ready for a fresh test run:"
    echo -e "  ${GREEN}./apply.sh ${MEETING_ID}${NC}"
fi
echo ""
