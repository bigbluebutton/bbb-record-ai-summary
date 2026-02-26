#!/bin/bash -e
BIGBLUEBUTTON_USER=bigbluebutton

case "$1" in
  configure|upgrade|1|2)

    TARGET=/usr/local/bigbluebutton/core/scripts/ai-summary.yml

    chmod +r $TARGET

    mkdir -p /var/bigbluebutton/published/ai-summary
    chown -R $BIGBLUEBUTTON_USER:$BIGBLUEBUTTON_USER /var/bigbluebutton/published/ai-summary
    chmod -R o+rx /var/bigbluebutton/published/

    mkdir -p /var/log/bigbluebutton/ai-summary
    chown -R $BIGBLUEBUTTON_USER:$BIGBLUEBUTTON_USER /var/log/bigbluebutton/ai-summary

    mkdir -p /var/bigbluebutton/recording/publish/ai-summary
    chown -R $BIGBLUEBUTTON_USER:$BIGBLUEBUTTON_USER /var/bigbluebutton/recording/publish/ai-summary

    # Create llm.yml from example if it doesn't already exist
    LLM_CONF=/usr/local/bigbluebutton/core/lib/ai-summary/llm.yml
    if [ ! -f "$LLM_CONF" ]; then
      cp "${LLM_CONF}.example" "$LLM_CONF"
      chown $BIGBLUEBUTTON_USER:$BIGBLUEBUTTON_USER "$LLM_CONF"
      chmod 640 "$LLM_CONF"
    fi

    systemctl reload nginx
  ;;

  failed-upgrade)
  ;;

  *)
    echo "## postinst called with unknown argument \`$1'" >&2
  ;;
esac
