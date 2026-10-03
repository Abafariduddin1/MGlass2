#!/usr/bin/env bash
set -euo pipefail
# Explicit candidates only: never recursively select a dSYM Mach-O file.
source_path='.theos/obj/MangaGlass.dylib'
if [[ ! -f "$source_path" ]]; then source_path='.theos/obj/arm64/MangaGlass.dylib'; fi
[[ -f "$source_path" ]] || { echo 'Compiled MangaGlass.dylib was not found.' >&2; exit 1; }
file "$source_path"
otool -hv "$source_path" | awk '/DYLIB/ { found=1 } END { exit !found }'
lipo -verify_arch arm64 "$source_path"
mkdir -p output
cp "$source_path" output/MangaGlass.dylib
