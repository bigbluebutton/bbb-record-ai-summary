#!/bin/bash -ex

TARGET=$(basename $(pwd))

PACKAGE=$(echo $TARGET | cut -d'_' -f1)
VERSION=$(echo $TARGET | cut -d'_' -f2)
DISTRO=$(echo $TARGET | cut -d'_' -f3)

# Locate project root: two levels up from this script's directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$PROJECT_ROOT/src/ai-summary"
POST_ARCHIVE_SRC="$PROJECT_ROOT/src/scripts/post_archive"

#
# Clear staging directory for build
rm -rf staging

#
# Create build directories for marking by fpm
DIRS="/usr/local/bigbluebutton/core/lib/ai-summary /usr/local/bigbluebutton/core/playback/ai-summary"
for dir in $DIRS; do
  mkdir -p staging$dir
  DIRECTORIES="$DIRECTORIES --directories $dir"
done

##

# Process and publish scripts
mkdir -p staging/usr/local/bigbluebutton/core/scripts/process
mkdir -p staging/usr/local/bigbluebutton/core/scripts/publish
cp "$SRC/process/ai-summary.rb" staging/usr/local/bigbluebutton/core/scripts/process/
cp "$SRC/publish/ai-summary.rb" staging/usr/local/bigbluebutton/core/scripts/publish/
chmod +x staging/usr/local/bigbluebutton/core/scripts/process/ai-summary.rb
chmod +x staging/usr/local/bigbluebutton/core/scripts/publish/ai-summary.rb

# Format config
cp "$SRC/ai-summary.yml" staging/usr/local/bigbluebutton/core/scripts/

# Post-archive transcription hook
mkdir -p staging/usr/local/bigbluebutton/core/scripts/post_archive
cp "$POST_ARCHIVE_SRC/transcribe_audio.rb" staging/usr/local/bigbluebutton/core/scripts/post_archive/
chmod +x staging/usr/local/bigbluebutton/core/scripts/post_archive/transcribe_audio.rb

# LLM library and config example (llm.yml itself is not packaged — configure on server)
cp "$SRC/lib/llm_client.rb" staging/usr/local/bigbluebutton/core/lib/ai-summary/
cp "$SRC/llm.yml.example" staging/usr/local/bigbluebutton/core/lib/ai-summary/

# ERB templates
cp "$SRC/templates/"*.erb staging/usr/local/bigbluebutton/core/playback/ai-summary/

# Nginx location block
mkdir -p staging/usr/share/bigbluebutton/nginx
cp "$SRC/ai-summary-playback.nginx" staging/usr/share/bigbluebutton/nginx/ai-summary.nginx

##

. "$SCRIPT_DIR/opts-$DISTRO.sh"

#
# Build package
fpm -s dir -C ./staging -n $PACKAGE \
    --version $VERSION --epoch $EPOCH \
    --post-install "$SCRIPT_DIR/before-install.sh" \
    --after-install "$SCRIPT_DIR/after-install.sh" \
    --description "BigBlueButton AI summary recording format" \
    $DIRECTORIES \
    $OPTS
