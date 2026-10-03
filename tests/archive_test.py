#!/usr/bin/env python3
"""Exercise the production EPUB ZIP extractor, including malformed containers."""
import ctypes
import io
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WORK = tempfile.TemporaryDirectory()
LIB = Path(WORK.name) / "archive.so"
subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
                *( ["-dynamiclib"] if sys.platform == "darwin" else ["-shared", "-fPIC"] ),
                str(ROOT / "MGArchive.c"), "-lz", "-o", str(LIB)], check=True)
library = ctypes.CDLL(str(LIB))
Writer = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t, ctypes.c_void_p)
library.MGArchiveExtract.argtypes = [ctypes.c_void_p, ctypes.c_size_t, Writer, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]
library.MGArchiveExtract.restype = ctypes.c_bool

def archive(entries, method=zipfile.ZIP_DEFLATED):
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=method) as container:
        for name, data in entries:
            container.writestr(name, data)
    return output.getvalue()

def extract(data, writable=True):
    entries = {}
    @Writer
    def writer(name, content, size, context):
        entries[name.decode("utf-8", errors="replace")] = ctypes.string_at(content, size)
        return writable
    detail = ctypes.create_string_buffer(200)
    source = ctypes.create_string_buffer(data)
    success = library.MGArchiveExtract(source, len(data), writer, None, detail, len(detail))
    return success, entries, detail.value.decode()

class ArchiveTests(unittest.TestCase):
    def test_deflated_container_roundtrip(self):
        files = [("mimetype", b"application/epub+zip"), ("EPUB/chapter.xhtml", b"<html>hello</html>" * 2000), ("EPUB/images/cover.png", bytes(range(256)))]
        self.assertEqual(extract(archive(files))[:2], (True, dict(files)))

    def test_stored_and_empty_entries(self):
        self.assertEqual(extract(archive([("empty.txt", b""), ("book.txt", b"hello")], zipfile.ZIP_STORED))[:2], (True, {"empty.txt": b"", "book.txt": b"hello"}))

    def test_empty_deflated_entry(self):
        self.assertTrue(extract(archive([("empty.txt", b"")]))[0])

    def test_utf8_paths_and_spaces(self):
        name = "EPUB/chapitre é 1.xhtml"
        self.assertEqual(extract(archive([(name, b"body")]))[:2], (True, {name: b"body"}))

    def test_directories(self):
        self.assertEqual(extract(archive([("EPUB/", b""), ("EPUB/a.txt", b"a")]))[:2], (True, {"EPUB/a.txt": b"a"}))

    def test_unsafe_paths(self):
        for name in ["../outside", "/absolute", "EPUB/../../outside", "EPUB/./file", "C:\\outside", "EPUB\\file", "EPUB//file"]:
            with self.subTest(name=name):
                good, files, error = extract(archive([(name, b"a")]))
                self.assertFalse(good); self.assertEqual(files, {}); self.assertIn("path", error)

    def test_symlinks(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as container:
            item = zipfile.ZipInfo("EPUB/link"); item.create_system = 3; item.external_attr = (0o120777 << 16)
            container.writestr(item, "../../outside")
        self.assertIn("symbolic", extract(output.getvalue())[2])

    def test_crc_mismatch(self):
        data = bytearray(archive([("book.txt", b"hello")], zipfile.ZIP_STORED))
        data[data.index(b"hello")] ^= 1
        self.assertIn("integrity", extract(bytes(data))[2])

    def test_truncated_archives(self):
        data = archive([("book.txt", b"hello")])
        for size in range(len(data)):
            self.assertFalse(extract(data[:size])[0])

    def test_trailing_garbage(self):
        self.assertFalse(extract(archive([("book.txt", b"hello")]) + b"bad")[0])

    def test_central_size_corruption(self):
        data = bytearray(archive([("book.txt", b"hello")]))
        struct.pack_into("<I", data, len(data) - 22 + 12, 0xffffffff)
        self.assertFalse(extract(bytes(data))[0])

    def test_size_limit_before_allocation(self):
        data = bytearray(archive([("book.txt", b"hello")]))
        struct.pack_into("<I", data, data.index(b"PK\x01\x02") + 24, 32 * 1024 * 1024 + 1)
        self.assertIn("size", extract(bytes(data))[2])

    def test_encrypted_zip(self):
        data = bytearray(archive([("book.txt", b"hello")]))
        for at, offset in [(0, 6), (data.index(b"PK\x01\x02"), 8)]:
            flags = struct.unpack_from("<H", data, at + offset)[0]; struct.pack_into("<H", data, at + offset, flags | 1)
        self.assertIn("encryption", extract(bytes(data))[2])

    def test_unsupported_compression(self):
        self.assertIn("compression", extract(archive([("book.txt", b"hello")], zipfile.ZIP_BZIP2))[2])

    def test_local_path_mismatch(self):
        data = bytearray(archive([("book.txt", b"hello")]))
        data[30] = ord("z")
        self.assertIn("mismatched", extract(bytes(data))[2])

    def test_callback_failure(self):
        self.assertFalse(extract(archive([("book.txt", b"hello")]), writable=False)[0])

    def test_duplicate_paths(self):
        import warnings
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            self.assertIn("duplicate", extract(archive([("book.txt", b"one"), ("book.txt", b"two")]))[2])

    def test_zip_comment(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as container:
            container.writestr("book.txt", b"hello"); container.comment = b"Comment PK\x05\x06"
        self.assertTrue(extract(output.getvalue())[0])

    def test_mutated_input_stays_bounded(self):
        seed = archive([("mimetype", b"application/epub+zip"), ("EPUB/chapter.xhtml", b"<html>ok</html>")])
        rng = random.Random(137)
        for _ in range(1000):
            data = bytearray(seed)
            for _ in range(rng.randint(1, 4)):
                data[rng.randrange(len(data))] ^= rng.randrange(1, 256)
            success, files, _ = extract(bytes(data))
            if success:
                self.assertEqual(sorted(files.values()), sorted([b"application/epub+zip", b"<html>ok</html>"]))

if __name__ == "__main__":
    unittest.main()
