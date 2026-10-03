#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

typedef enum { MGLeftToRight = 0, MGRightToLeft = 1, MGVertical = 2 } MGDirection;
typedef enum { MGWholePage = 0, MGLeftHalf = 1, MGRightHalf = 2 } MGHalf;
typedef struct { double width, height; } MGPageSize;
typedef struct { size_t source; MGHalf half; } MGSegment;
typedef struct { size_t first, count; } MGGroup;
typedef struct { size_t segmentCount, groupCount; } MGPlan;
typedef struct { double x, y, width, height; } MGUnitRect;

// Allocate segment/group buffers with MGPlanCapacity(count) elements each.
// Groups are always in logical reading order; the UI reverses horizontal RTL cells.
size_t MGPlanCapacity(size_t count);
MGPlan MGMakePlan(const MGPageSize *pages, size_t count, double width, double height,
                  MGDirection direction, bool split, bool pair, bool singleCover,
                  MGSegment *segments, MGGroup *groups, size_t capacity);
size_t MGFindGroup(const MGSegment *segments, const MGGroup *groups, MGPlan plan,
                   size_t source, MGHalf half);
size_t MGDisplayIndex(size_t logical, size_t count, MGDirection direction);
// Whole scans retain a half anchor so portrait -> landscape -> portrait does not
// restart a spread at its first half. Vertical mode can request MGWholePage.
MGHalf MGResolveHalf(const MGSegment *segments, MGPlan plan, size_t source, MGHalf desired);
MGUnitRect MGContentBounds(const uint8_t *rgba, size_t width, size_t height, size_t stride);
