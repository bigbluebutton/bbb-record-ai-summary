#!/bin/bash
# Compare local test harness output with BigBlueButton server output

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# Check if meeting ID is provided
if [ -z "$1" ]; then
    echo -e "${RED}Error: Meeting ID required${NC}"
    echo "Usage: $0 <meeting_id>"
    exit 1
fi

MEETING_ID="$1"

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Comparing Local vs Server Recording Output             ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Meeting ID: ${MEETING_ID}"
echo ""

# Check if local processing was done
if [ ! -d "recording/process/notes/${MEETING_ID}" ] && [ ! -d "recording/publish/notes/${MEETING_ID}" ]; then
    echo -e "${RED}Error: No local output found for ${MEETING_ID}${NC}"
    echo "Run ./apply.sh ${MEETING_ID} first"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}1. DIRECTORY STRUCTURE COMPARISON${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Compare process directory
echo -e "${BLUE}Process Directory:${NC}"
LOCAL_PROCESS="recording/process/notes/${MEETING_ID}"
SERVER_PROCESS="/var/bigbluebutton/recording/process/notes/${MEETING_ID}"

if [ -d "$LOCAL_PROCESS" ]; then
    echo -e "  Local:  ${GREEN}✓${NC} $LOCAL_PROCESS"
    ls -lh "$LOCAL_PROCESS" | tail -n +2 | awk '{print "          - " $9 " (" $5 ")"}'
else
    echo -e "  Local:  ${RED}✗${NC} Not found"
fi

if [ -d "$SERVER_PROCESS" ]; then
    echo -e "  Server: ${GREEN}✓${NC} $SERVER_PROCESS"
    ls -lh "$SERVER_PROCESS" | tail -n +2 | awk '{print "          - " $9 " (" $5 ")"}'
else
    echo -e "  Server: ${YELLOW}✗${NC} Not found (may not have been run on server)"
fi
echo ""

# Compare publish directory
echo -e "${BLUE}Publish Directory:${NC}"
LOCAL_PUBLISH="recording/publish/notes/${MEETING_ID}"
SERVER_PUBLISH="/var/bigbluebutton/published/notes/${MEETING_ID}"

if [ -d "$LOCAL_PUBLISH" ]; then
    echo -e "  Local:  ${GREEN}✓${NC} $LOCAL_PUBLISH"
    ls -lh "$LOCAL_PUBLISH" | tail -n +2 | awk '{print "          - " $9 " (" $5 ")"}'
else
    echo -e "  Local:  ${RED}✗${NC} Not found"
fi

if [ -d "$SERVER_PUBLISH" ]; then
    echo -e "  Server: ${GREEN}✓${NC} $SERVER_PUBLISH"
    ls -lh "$SERVER_PUBLISH" | tail -n +2 | awk '{print "          - " $9 " (" $5 ")"}'
else
    echo -e "  Server: ${YELLOW}✗${NC} Not found (may not have been published on server)"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}2. STATUS FILES COMPARISON${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check processed status
echo -e "${BLUE}Processed Status:${NC}"
LOCAL_PROC_DONE="recording/status/processed/${MEETING_ID}-notes.done"
SERVER_PROC_DONE="/var/bigbluebutton/recording/status/processed/${MEETING_ID}-notes.done"

if [ -f "$LOCAL_PROC_DONE" ]; then
    echo -e "  Local:  ${GREEN}✓${NC} $LOCAL_PROC_DONE"
    echo -e "          Content: $(cat $LOCAL_PROC_DONE)"
else
    echo -e "  Local:  ${RED}✗${NC} Not found"
fi

if [ -f "$SERVER_PROC_DONE" ]; then
    echo -e "  Server: ${GREEN}✓${NC} $SERVER_PROC_DONE"
    echo -e "          Content: $(cat $SERVER_PROC_DONE)"
else
    echo -e "  Server: ${YELLOW}✗${NC} Not found"
fi
echo ""

# Check published status
echo -e "${BLUE}Published Status:${NC}"
LOCAL_PUB_DONE="recording/status/published/${MEETING_ID}-notes.done"
SERVER_PUB_DONE="/var/bigbluebutton/recording/status/published/${MEETING_ID}-notes.done"

if [ -f "$LOCAL_PUB_DONE" ]; then
    echo -e "  Local:  ${GREEN}✓${NC} $LOCAL_PUB_DONE"
    echo -e "          Content: $(cat $LOCAL_PUB_DONE)"
else
    echo -e "  Local:  ${RED}✗${NC} Not found"
fi

if [ -f "$SERVER_PUB_DONE" ]; then
    echo -e "  Server: ${GREEN}✓${NC} $SERVER_PUB_DONE"
    echo -e "          Content: $(cat $SERVER_PUB_DONE)"
else
    echo -e "  Server: ${YELLOW}✗${NC} Not found"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}3. METADATA.XML COMPARISON${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Compare processed metadata
if [ -f "$LOCAL_PROCESS/metadata.xml" ]; then
    echo -e "${BLUE}Local Processed Metadata (key fields):${NC}"
    echo "  State: $(xmllint --xpath '//recording/state/text()' $LOCAL_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Published: $(xmllint --xpath '//recording/published/text()' $LOCAL_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Start Time: $(xmllint --xpath '//recording/start_time/text()' $LOCAL_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  End Time: $(xmllint --xpath '//recording/end_time/text()' $LOCAL_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo ""
fi

if [ -f "$SERVER_PROCESS/metadata.xml" ]; then
    echo -e "${BLUE}Server Processed Metadata (key fields):${NC}"
    echo "  State: $(xmllint --xpath '//recording/state/text()' $SERVER_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Published: $(xmllint --xpath '//recording/published/text()' $SERVER_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Start Time: $(xmllint --xpath '//recording/start_time/text()' $SERVER_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  End Time: $(xmllint --xpath '//recording/end_time/text()' $SERVER_PROCESS/metadata.xml 2>/dev/null || echo 'N/A')"
    echo ""
fi

# Compare published metadata
if [ -f "$LOCAL_PUBLISH/metadata.xml" ]; then
    echo -e "${BLUE}Local Published Metadata (key fields):${NC}"
    echo "  State: $(xmllint --xpath '//recording/state/text()' $LOCAL_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Published: $(xmllint --xpath '//recording/published/text()' $LOCAL_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Format: $(xmllint --xpath '//recording/playback/format/text()' $LOCAL_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Link: $(xmllint --xpath '//recording/playback/link/text()' $LOCAL_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Duration: $(xmllint --xpath '//recording/playback/duration/text()' $LOCAL_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo ""
fi

if [ -f "$SERVER_PUBLISH/metadata.xml" ]; then
    echo -e "${BLUE}Server Published Metadata (key fields):${NC}"
    echo "  State: $(xmllint --xpath '//recording/state/text()' $SERVER_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Published: $(xmllint --xpath '//recording/published/text()' $SERVER_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Format: $(xmllint --xpath '//recording/playback/format/text()' $SERVER_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Link: $(xmllint --xpath '//recording/playback/link/text()' $SERVER_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo "  Duration: $(xmllint --xpath '//recording/playback/duration/text()' $SERVER_PUBLISH/metadata.xml 2>/dev/null || echo 'N/A')"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}4. FILE CONTENT COMPARISON${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Compare notes.pdf files
LOCAL_PDF="$LOCAL_PUBLISH/notes.pdf"
SERVER_PDF="$SERVER_PUBLISH/notes.pdf"

if [ -f "$LOCAL_PDF" ] && [ -f "$SERVER_PDF" ]; then
    LOCAL_SIZE=$(stat -f%z "$LOCAL_PDF" 2>/dev/null || stat -c%s "$LOCAL_PDF" 2>/dev/null)
    SERVER_SIZE=$(stat -f%z "$SERVER_PDF" 2>/dev/null || stat -c%s "$SERVER_PDF" 2>/dev/null)

    echo -e "${BLUE}notes.pdf Comparison:${NC}"
    echo "  Local size:  $LOCAL_SIZE bytes"
    echo "  Server size: $SERVER_SIZE bytes"

    if [ "$LOCAL_SIZE" -eq "$SERVER_SIZE" ]; then
        echo -e "  ${GREEN}✓ File sizes match${NC}"
    else
        echo -e "  ${YELLOW}! File sizes differ${NC}"
    fi
elif [ -f "$LOCAL_PDF" ]; then
    echo -e "${BLUE}notes.pdf:${NC}"
    echo -e "  Local:  ${GREEN}✓${NC} Present"
    echo -e "  Server: ${YELLOW}✗${NC} Not found"
elif [ -f "$SERVER_PDF" ]; then
    echo -e "${BLUE}notes.pdf:${NC}"
    echo -e "  Local:  ${YELLOW}✗${NC} Not found"
    echo -e "  Server: ${GREEN}✓${NC} Present"
fi
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${YELLOW}5. SUMMARY${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ERRORS=0
WARNINGS=0

# Check local outputs exist
if [ ! -d "$LOCAL_PROCESS" ]; then
    echo -e "${RED}✗ Local process directory missing${NC}"
    ((ERRORS++))
fi

if [ ! -d "$LOCAL_PUBLISH" ]; then
    echo -e "${RED}✗ Local publish directory missing${NC}"
    ((ERRORS++))
fi

if [ ! -f "$LOCAL_PROC_DONE" ]; then
    echo -e "${RED}✗ Local processed status file missing${NC}"
    ((ERRORS++))
fi

if [ ! -f "$LOCAL_PUB_DONE" ]; then
    echo -e "${RED}✗ Local published status file missing${NC}"
    ((ERRORS++))
fi

# Compare with server if it exists
if [ -d "$SERVER_PROCESS" ] && [ -d "$LOCAL_PROCESS" ]; then
    echo -e "${GREEN}✓ Both local and server process directories exist${NC}"
else
    echo -e "${YELLOW}⚠ Server process directory not found (recording may not have run on server)${NC}"
    ((WARNINGS++))
fi

if [ -d "$SERVER_PUBLISH" ] && [ -d "$LOCAL_PUBLISH" ]; then
    echo -e "${GREEN}✓ Both local and server publish directories exist${NC}"
else
    echo -e "${YELLOW}⚠ Server publish directory not found (recording may not have been published on server)${NC}"
    ((WARNINGS++))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}✓ Test harness is working correctly!${NC}"
    if [ $WARNINGS -gt 0 ]; then
        echo -e "${YELLOW}⚠ $WARNINGS warning(s) - server files may not exist yet${NC}"
    fi
else
    echo -e "${RED}✗ $ERRORS error(s) found${NC}"
    exit 1
fi
echo ""
