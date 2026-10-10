#!/bin/sh
# Downloads the two OFL fonts the compositors set marketing type in, from Google's fonts
# repository, into fonts/ (gitignored: 12.8 MB). The licences are kept next to them.
# Pinned to a google/fonts commit, not main: the creative generator checks the fonts' sha256
# (creative/generate.mjs), and new bytes would move glyphs and the rendered PNGs. e1d6480 is
# the last commit to touch any of these four files as of 2026-10-10.
set -e
cd "$(dirname "$0")"
mkdir -p fonts
base=https://github.com/google/fonts/raw/e1d6480102fed30739fead0faee463101f892c8f/ofl
curl -sfL -o fonts/NotoSansTC-wght.ttf "$base/notosanstc/NotoSansTC%5Bwght%5D.ttf"
curl -sfL -o fonts/Inter-opsz-wght.ttf "$base/inter/Inter%5Bopsz,wght%5D.ttf"
curl -sfL -o fonts/OFL-NotoSansTC.txt "$base/notosanstc/OFL.txt"
curl -sfL -o fonts/OFL-Inter.txt "$base/inter/OFL.txt"
ls -l fonts
shasum -a 256 fonts/*.ttf
