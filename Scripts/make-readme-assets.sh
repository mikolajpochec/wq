#!/bin/bash
# Turns the frames and keycaps from the `readme-render <dir>` debug command into the README's
# pictures in docs/assets. Needs ffmpeg. Usage: Scripts/make-readme-assets.sh <dir>
set -euo pipefail
cd "$(dirname "$0")/.."
SRC=${1:?usage: make-readme-assets.sh <readme-render output dir>}
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
