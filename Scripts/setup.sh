#!/usr/bin/env bash
# One-shot setup for building YTWatch from source.
# Installs missing prerequisites, generates the Xcode project, and opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking prerequisites"

if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "==> Installing XcodeGen via Homebrew"
    brew install xcodegen
  else
    echo "XcodeGen is required but not installed, and Homebrew isn't available."
    echo "Install Homebrew (https://brew.sh) then run: brew install xcodegen"
    exit 1
  fi
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "==> Installing yt-dlp (needed by Scripts/server.py) via pip3"
  pip3 install --user yt-dlp flask
fi

echo "==> Generating YTWatch.xcodeproj"
xcodegen generate

echo "==> Opening in Xcode"
open YTWatch.xcodeproj

cat <<'EOF'

Next steps:
  1. In Xcode: Signing & Capabilities -> pick your Team for BOTH
     the "YTWatch" and "YTWatch Watch App" targets.
  2. Plug in your iPhone (Watch paired nearby), select the YTWatch
     scheme, and hit Run.
  3. Start the download server: python3 Scripts/server.py
  4. In the iPhone app's Settings tab, enter the server URL it prints.

Full walkthrough: Scripts/README.md
EOF
