#!/bin/bash
# Draws the README's pictures into docs/assets: scenes on the tour's pretend desktop as GIFs, and
# each feature's keys as SVG. Runs a one-off `WindowQueue --render readme`, so a running copy of
# the app is left alone. Needs ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=$(mktemp -d -t windowqueue-readme)
trap 'rm -rf "$SRC"' EXIT
swift build >/dev/null
"$(swift build --show-bin-path)/WindowQueue" --render readme "$SRC"
OUT=docs/assets
mkdir -p "$OUT"
for scene in "$SRC"/*/; do
    name=$(basename "$scene")
    # Opaque, a fixed palette and no dithering: frames that only change where something moves,
    # which keeps each GIF in the hundreds of kilobytes.
    ffmpeg -loglevel error -y -framerate 15 -i "$scene/frame-%04d.png" \
        -vf "fps=15,scale=600:-1:flags=lanczos,format=rgb24,split[a][b];[a]palettegen=max_colors=128:stats_mode=full:reserve_transparent=0[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
        -gifflags +offsetting+transdiff -loop 0 "$OUT/$name.gif"
done
cp "$SRC"/keys-*.svg "$OUT/"
ls -la "$OUT" | awk 'NR>3 {print $5, $9}'
