#include "MGReaderGeometry.h"
#include <math.h>
#include <stdint.h>

size_t MGPlanCapacity(size_t count) { return count > SIZE_MAX / 2 ? 0 : count * 2; }

static bool wide(MGPageSize page) {
    return page.width > 0 && page.height > 0 && page.width / page.height >= 1.2;
}

MGPlan MGMakePlan(const MGPageSize *pages, size_t count, double width, double height,
                  MGDirection direction, bool split, bool pair, bool singleCover,
                  MGSegment *segments, MGGroup *groups, size_t capacity) {
    MGPlan result = {0, 0};
    if (!count || !pages || !segments || !groups || !isfinite(width) || !isfinite(height) ||
        width <= 0 || height <= 0 || !MGPlanCapacity(count) || capacity < MGPlanCapacity(count)) return result;
    bool portrait = width < height;
    bool doublePages = pair && direction != MGVertical && width >= 600 && width / height >= 1.25;
    for (size_t i = 0; i < count; i++) {
        bool cut = split && portrait && direction != MGVertical && wide(pages[i]);
        segments[result.segmentCount++] = (MGSegment){i, cut ? (direction == MGRightToLeft ? MGRightHalf : MGLeftHalf) : MGWholePage};
        if (cut) segments[result.segmentCount++] = (MGSegment){i, direction == MGRightToLeft ? MGLeftHalf : MGRightHalf};
    }
    for (size_t i = 0; i < result.segmentCount;) {
        size_t number = 1;
        size_t source = segments[i].source;
        bool cover = singleCover && source == 0;
        if (doublePages && !cover && !wide(pages[source]) && i + 1 < result.segmentCount &&
            !wide(pages[segments[i + 1].source])) number = 2;
        groups[result.groupCount++] = (MGGroup){i, number};
        i += number;
    }
    return result;
}

size_t MGFindGroup(const MGSegment *segments, const MGGroup *groups, MGPlan plan,
                   size_t source, MGHalf half) {
    size_t fallback = 0;
    bool found = false;
    for (size_t i = 0; i < plan.groupCount; i++) {
        for (size_t j = 0; j < groups[i].count; j++) {
            MGSegment segment = segments[groups[i].first + j];
            if (segment.source != source) continue;
            if (segment.half == half || segment.half == MGWholePage) return i;
            if (!found) { fallback = i; found = true; }
        }
    }
    return fallback;
}

size_t MGDisplayIndex(size_t logical, size_t count, MGDirection direction) {
    if (!count || logical >= count) return 0;
    return direction == MGRightToLeft ? count - 1 - logical : logical;
}

MGHalf MGResolveHalf(const MGSegment *segments, MGPlan plan, size_t source, MGHalf desired) {
    if (desired < MGWholePage || desired > MGRightHalf) desired = MGWholePage;
    MGHalf fallback = MGWholePage;
    for (size_t i = 0; i < plan.segmentCount; i++) {
        MGSegment segment = segments[i];
        if (segment.source != source) continue;
        if (segment.half == MGWholePage || segment.half == desired) return desired;
        if (fallback == MGWholePage) fallback = segment.half;
    }
    return fallback;
}

MGUnitRect MGContentBounds(const uint8_t *rgba, size_t width, size_t height, size_t stride) {
    MGUnitRect full = {0, 0, 1, 1};
    if (!rgba || !width || !height || width > SIZE_MAX / 4 || stride < width * 4 || height > SIZE_MAX / stride) return full;
    size_t left = width, top = height, right = 0, bottom = 0;
    bool found = false;
    for (size_t y = 0; y < height; y++) for (size_t x = 0; x < width; x++) {
        const uint8_t *p = rgba + y * stride + x * 4;
        if (p[3] < 128 || (p[0] >= 246 && p[1] >= 246 && p[2] >= 246)) continue;
        found = true;
        if (x < left) left = x;
        if (x > right) right = x;
        if (y < top) top = y;
        if (y > bottom) bottom = y;
    }
    // A scan can occupy only the centre of an oversized PDF sheet. Keep blank
    // pages and isolated page numbers intact, but let real centred artwork fit.
    double contentWidth = found ? (double)(right - left + 1) / width : 0;
    double contentHeight = found ? (double)(bottom - top + 1) / height : 0;
    if (!found || contentWidth < .15 || contentHeight < .15 || contentWidth * contentHeight < .08) return full;
    size_t padX = width / 100 + 1, padY = height / 100 + 1;
    left = left > padX ? left - padX : 0;
    top = top > padY ? top - padY : 0;
    right = right + padX < width ? right + padX : width - 1;
    bottom = bottom + padY < height ? bottom + padY : height - 1;
    return (MGUnitRect){(double)left / width, (double)top / height,
                        (double)(right - left + 1) / width, (double)(bottom - top + 1) / height};
}
