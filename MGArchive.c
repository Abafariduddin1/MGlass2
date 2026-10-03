#include "MGArchive.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <zlib.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1] << 8)); }
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }
static bool range(size_t at, size_t size, size_t length) { return at <= length && size <= length - at; }
static bool fail(char *error, size_t size, const char *message) { if (error && size) snprintf(error, size, "%s", message); return false; }
static bool safePath(const char *path, size_t length) {
    if (!length || path[0] == '/' || path[0] == '\\') return false;
    size_t start = 0;
    for (size_t i = 0; i <= length; i++) {
        if (i < length && (path[i] == '\\' || path[i] == ':' || (unsigned char)path[i] < 32)) return false;
        if (i == length || path[i] == '/') {
            size_t part = i - start;
            if (!part && i != length) return false;
            if ((part == 1 && path[start] == '.') || (part == 2 && path[start] == '.' && path[start + 1] == '.')) return false;
            start = i + 1;
        }
    }
    return true;
}

bool MGArchiveExtract(const uint8_t *bytes, size_t length, MGArchiveWriter writer, void *context, char *error, size_t errorSize) {
    if (!bytes || !writer || length < 22) return fail(error, errorSize, "This EPUB is not a valid ZIP container.");
    size_t tail = length - 22, earliest = length > 65557 ? length - 65557 : 0;
    bool found = false;
    for (;;) {
        if (u32(bytes + tail) == 0x06054b50 && range(tail, 22, length) && tail + 22 + u16(bytes + tail + 20) == length) { found = true; break; }
        if (tail == earliest) break;
        tail--;
    }
    if (!found) return fail(error, errorSize, "The EPUB archive is incomplete.");
    uint16_t count = u16(bytes + tail + 10);
    uint32_t centralSize = u32(bytes + tail + 12), centralOffset = u32(bytes + tail + 16);
    if (u16(bytes + tail + 4) || u16(bytes + tail + 6) || count != u16(bytes + tail + 8) || count == UINT16_MAX || centralOffset == UINT32_MAX || centralSize == UINT32_MAX)
        return fail(error, errorSize, "Split and ZIP64 EPUB archives are not supported.");
    if (!count || count > 4096 || !range(centralOffset, centralSize, tail)) return fail(error, errorSize, "The EPUB archive is too large or invalid.");
    size_t cursor = centralOffset, centralEnd = cursor + centralSize, total = 0;
    uint64_t pathHashes[4096] = {0};
    for (uint16_t index = 0; index < count; index++) {
        if (!range(cursor, 46, centralEnd) || u32(bytes + cursor) != 0x02014b50) return fail(error, errorSize, "The EPUB file index is damaged.");
        const uint8_t *entry = bytes + cursor;
        uint16_t flags = u16(entry + 8), method = u16(entry + 10), nameSize = u16(entry + 28), extra = u16(entry + 30), comment = u16(entry + 32);
        uint32_t compressed = u32(entry + 20), unpacked = u32(entry + 24), offset = u32(entry + 42), checksum = u32(entry + 16);
        size_t entrySize = (size_t)46 + nameSize + extra + comment;
        if (!range(cursor, entrySize, centralEnd) || !nameSize || nameSize > 2048 || !safePath((const char *)(entry + 46), nameSize)) return fail(error, errorSize, "An EPUB file has an unsafe path.");
        uint64_t hash = UINT64_C(14695981039346656037);
        for (uint16_t i = 0; i < nameSize; i++) { hash ^= entry[46 + i]; hash *= UINT64_C(1099511628211); }
        for (uint16_t i = 0; i < index; i++) if (pathHashes[i] == hash) return fail(error, errorSize, "The EPUB contains duplicate file paths.");
        pathHashes[index] = hash;
        if ((flags & 1) || (flags & 0x40) || (method != 0 && method != 8) || u16(entry + 34)) return fail(error, errorSize, "This EPUB uses unsupported ZIP encryption or compression.");
        if ((u32(entry + 38) >> 16 & 0xf000) == 0xa000) return fail(error, errorSize, "EPUB symbolic links are not supported.");
        if (unpacked > 32U * 1024 * 1024 || total > 256U * 1024 * 1024 - unpacked) return fail(error, errorSize, "The EPUB exceeds the safe extraction size.");
        total += unpacked;
        if (!range(offset, 30, centralOffset) || u32(bytes + offset) != 0x04034b50) return fail(error, errorSize, "An EPUB file header is damaged.");
        size_t localName = u16(bytes + offset + 26), localExtra = u16(bytes + offset + 28), dataOffset = (size_t)offset + 30 + localName + localExtra;
        if (!range(offset + 30, localName + localExtra, centralOffset) || localName != nameSize || memcmp(bytes + offset + 30, entry + 46, nameSize) ||
            u16(bytes + offset + 8) != method || u16(bytes + offset + 6) != flags || !range(dataOffset, compressed, centralOffset)) return fail(error, errorSize, "An EPUB file is truncated or mismatched.");
        char path[2049]; memcpy(path, entry + 46, nameSize); path[nameSize] = 0;
        cursor += entrySize;
        if (path[nameSize - 1] == '/') continue;
        uint8_t *output = malloc((size_t)unpacked + 1);
        if (!output) return fail(error, errorSize, "There is not enough memory to open this EPUB.");
        bool valid = false;
        if (method == 0) {
            valid = compressed == unpacked;
            if (valid && unpacked) memcpy(output, bytes + dataOffset, unpacked);
        } else {
            z_stream stream; memset(&stream, 0, sizeof(stream));
            stream.next_in = (Bytef *)(bytes + dataOffset); stream.avail_in = compressed;
            stream.next_out = output; stream.avail_out = unpacked + 1;
            if (inflateInit2(&stream, -MAX_WBITS) == Z_OK) {
                int status = inflate(&stream, Z_FINISH);
                valid = status == Z_STREAM_END && stream.total_out == unpacked && stream.total_in == compressed;
                inflateEnd(&stream);
            }
        }
        valid = valid && (uint32_t)crc32(0L, output, unpacked) == checksum;
        bool written = valid && writer(path, output, unpacked, context);
        free(output);
        if (!written) return fail(error, errorSize, valid ? "The EPUB could not be extracted." : "An EPUB file failed its integrity check.");
    }
    if (cursor != centralEnd) return fail(error, errorSize, "The EPUB file index has trailing invalid data.");
    return true;
}
