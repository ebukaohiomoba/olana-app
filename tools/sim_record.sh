#!/bin/zsh
# sim_record.sh: launch the app on the simulator (optionally on a fixture),
# record the screen for N seconds, and make a filmstrip of it.
#
#   tools/sim_record.sh <outdir> <name> [seconds=6] [fixture] [fps=8] [light|dark]
#
# Writes <outdir>/<name>.mp4 and <outdir>/<name>_frames.png. The app must
# already be installed (build and `simctl install` first).

set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
OUT=$1; NAME=$2; SECS=${3:-6}; FIXTURE=$4; FPS=${5:-8}; LOOK=${6:-light}
ID=${SIM_ID:-FD20C371-EF39-4EA3-A6B8-72B0A05CD8E0}
BUNDLE=${BUNDLE:-Rhejoys.Olana}
HERE=${0:A:h}

xcrun simctl boot $ID 2>/dev/null || true
xcrun simctl ui $ID appearance $LOOK
xcrun simctl terminate $ID $BUNDLE 2>/dev/null || true
rm -f $OUT/$NAME.mp4

# Start recording first so the launch is captured.
xcrun simctl io $ID recordVideo --codec h264 --force $OUT/$NAME.mp4 >/dev/null 2>&1 &
REC=$!
sleep 1
if [[ -n "$FIXTURE" ]]; then
  xcrun simctl launch $ID $BUNDLE -homeFixture $FIXTURE >/dev/null
else
  xcrun simctl launch $ID $BUNDLE >/dev/null
fi
sleep $SECS
kill -INT $REC
wait $REC 2>/dev/null || true

swift $HERE/frames.swift $OUT/$NAME.mp4 $OUT/${NAME}_frames.png $FPS 8 150
