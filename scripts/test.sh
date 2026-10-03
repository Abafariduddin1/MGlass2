#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
cc -std=c11 -Wall -Wextra -Werror -pedantic MGReaderGeometry.c tests/reader_geometry_test.c -lm -o "$test_dir/reader_geometry_test"
"$test_dir/reader_geometry_test"
python3 tests/archive_test.py
if [[ "$(uname -s)" == 'Darwin' ]]; then
    python3 tests/epub_fixtures.py "$test_dir/epubs"
    cc -std=c11 -Wall -Wextra -Werror -c MGArchive.c -o "$test_dir/archive.o"
    cc -fobjc-arc -Wall -Wextra -Werror MGEpubBook.m tests/epub_book_test.m "$test_dir/archive.o" -framework Foundation -lz -o "$test_dir/epub_book_test"
    "$test_dir/epub_book_test" "$test_dir/epubs"
fi
node --test worker/worker.test.mjs
