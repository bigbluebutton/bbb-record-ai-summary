#!/bin/bash

set -euo pipefail

PROJECT_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ "$EUID" -ne 0 ]; then
  echo "Root privileges required. Re-running with sudo..."
  exec sudo "$0" "$@"
fi

mkdir -p /etc/bigbluebutton

if [ -f "$PROJECT_ROOT/src/ai-summary/ai-summary-override.yml" ]; then
  cp "$PROJECT_ROOT/src/ai-summary/ai-summary-override.yml" /etc/bigbluebutton/ai-summary.yml
  echo "Deployed: /etc/bigbluebutton/ai-summary.yml"
fi

if [ -f "$PROJECT_ROOT/src/scripts/transcription/transcription-override.yml" ]; then
  cp "$PROJECT_ROOT/src/scripts/transcription/transcription-override.yml" /etc/bigbluebutton/post-archive-transcription.yml
  echo "Deployed: /etc/bigbluebutton/post-archive-transcription.yml"
fi
