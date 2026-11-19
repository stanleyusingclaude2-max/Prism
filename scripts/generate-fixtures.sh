#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$project_dir/Playit/Resources/Fixtures"
mkdir -p "$fixture_dir"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=640x360:rate=30:duration=3' \
  -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=3' \
  -c:v libx264 -preset veryfast -crf 27 -pix_fmt yuv420p -c:a aac -b:a 48k \
  -movflags +faststart -shortest "$fixture_dir/sample-motion.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=30:duration=2' \
  -vf "select='not(mod(n,3))+not(mod(n,5))'" -fps_mode vfr \
  -c:v libx264 -preset veryfast -crf 29 -pix_fmt yuv420p "$fixture_dir/sample-variable.mkv"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=320x180:rate=25:duration=2' \
  -c:v mpeg4 -q:v 8 "$fixture_dir/sample-legacy.avi"
ffmpeg -hide_banner -loglevel error -y -i "$fixture_dir/sample-motion.mp4" \
  -frames:v 1 "$fixture_dir/sample-still.png"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i 'testsrc2=size=180x320:rate=30:duration=2' \
  -c:v libx264 -preset veryfast -crf 27 -pix_fmt yuv420p -movflags +faststart \
  "$fixture_dir/sample-portrait.mov"
ffmpeg -hide_banner -loglevel error -y -display_rotation:v:0 90 -i "$fixture_dir/sample-motion.mp4" \
  -c copy -movflags +faststart "$fixture_dir/sample-rotated.mov"
