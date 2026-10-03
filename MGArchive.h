#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

// ZIP32 stored/deflated entries. The callback receives one verified file at a
// time. Bounds, paths, CRCs, unsupported encryption and symlinks are checked.
typedef bool (*MGArchiveWriter)(const char *path, const uint8_t *data, size_t length, void *context);
bool MGArchiveExtract(const uint8_t *bytes, size_t length, MGArchiveWriter writer,
                      void *context, char *error, size_t errorSize);
