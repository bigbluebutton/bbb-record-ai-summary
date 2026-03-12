#!/bin/bash
set -euo pipefail

dpkg-buildpackage -us -uc -b
echo ""
echo "Package built: $(ls ../bbb-record-ai-summary_*.deb | tail -1)"
