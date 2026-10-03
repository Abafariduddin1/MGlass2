#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pedantic MGReaderGeometry.c tests/reader_geometry_test.c -lm -o "$test_dir/reader_geometry_test"
"$test_dir/reader_geometry_test"
node --test worker/worker.test.mjs
