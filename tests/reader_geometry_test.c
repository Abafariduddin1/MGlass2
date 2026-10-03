#include "../MGReaderGeometry.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned tests;
static MGSegment segments[200];
static MGGroup groups[200];
#define PASS() do { tests++; } while (0)

int main(void) {
    MGPageSize singles[] = {{700, 1000}, {700, 1000}, {700, 1000}, {700, 1000}, {700, 1000}};
    MGPageSize mixed[] = {{700, 1000}, {1400, 1000}, {700, 1000}, {700, 1000}};
    MGPlan p = MGMakePlan(singles, 5, 390, 750, MGRightToLeft, true, true, true, segments, groups, 200);
    assert(p.segmentCount == 5 && p.groupCount == 5); PASS();
    assert(MGDisplayIndex(0, p.groupCount, MGRightToLeft) == 4); PASS();
    p = MGMakePlan(singles, 5, 844, 340, MGRightToLeft, true, true, true, segments, groups, 200);
    assert(p.groupCount == 3 && groups[0].count == 1 && groups[1].count == 2 && groups[2].count == 2); PASS();
    p = MGMakePlan(singles, 5, 844, 340, MGLeftToRight, true, true, false, segments, groups, 200);
    assert(p.groupCount == 3 && groups[0].count == 2 && groups[2].count == 1); PASS();
    p = MGMakePlan(mixed, 4, 390, 750, MGRightToLeft, true, true, true, segments, groups, 200);
    assert(p.segmentCount == 5 && segments[1].source == 1 && segments[1].half == MGRightHalf && segments[2].half == MGLeftHalf); PASS();
    assert(MGFindGroup(segments, groups, p, 1, MGLeftHalf) == 2); PASS();
    p = MGMakePlan(mixed, 4, 390, 750, MGLeftToRight, true, true, true, segments, groups, 200);
    assert(segments[1].half == MGLeftHalf && segments[2].half == MGRightHalf); PASS();
    p = MGMakePlan(mixed, 4, 844, 340, MGRightToLeft, true, true, true, segments, groups, 200);
    assert(p.segmentCount == 4 && p.groupCount == 3 && groups[1].count == 1 && groups[2].count == 2); PASS();
    assert(MGFindGroup(segments, groups, p, 1, MGLeftHalf) == 1); PASS();
    MGHalf anchor = MGResolveHalf(segments, p, 1, MGLeftHalf);
    assert(anchor == MGLeftHalf); PASS();
    p = MGMakePlan(mixed, 4, 390, 750, MGRightToLeft, true, true, true, segments, groups, 200);
    anchor = MGResolveHalf(segments, p, 1, anchor);
    assert(anchor == MGLeftHalf && MGFindGroup(segments, groups, p, 1, anchor) == 2); PASS();
    assert(MGResolveHalf(segments, p, 1, MGWholePage) == MGRightHalf); PASS();
    p = MGMakePlan(mixed, 4, 390, 750, MGVertical, true, true, false, segments, groups, 200);
    assert(p.segmentCount == 4 && p.groupCount == 4 && segments[1].half == MGWholePage); PASS();
    assert(MGDisplayIndex(2, 4, MGVertical) == 2); PASS();
    p = MGMakePlan(singles, 5, 500, 300, MGRightToLeft, true, true, true, segments, groups, 200);
    assert(p.groupCount == 5); PASS();
    p = MGMakePlan(singles, 5, 844, 340, MGRightToLeft, true, false, false, segments, groups, 200);
    assert(p.groupCount == 5); PASS();
    p = MGMakePlan(mixed, 4, 390, 750, MGRightToLeft, false, true, true, segments, groups, 200);
    assert(p.segmentCount == 4); PASS();
    assert(MGMakePlan(singles, 5, 390, 750, MGRightToLeft, true, true, true, segments, groups, 9).groupCount == 0); PASS();
    assert(MGMakePlan(singles, 5, NAN, 750, MGRightToLeft, true, true, true, segments, groups, 200).groupCount == 0); PASS();
    assert(MGMakePlan(NULL, 0, 0, 0, MGRightToLeft, true, true, true, segments, groups, 200).groupCount == 0); PASS();
    assert(MGPlanCapacity(SIZE_MAX) == 0 && MGPlanCapacity(5) == 10); PASS();
    uint8_t bitmap[100 * 100 * 4]; memset(bitmap, 255, sizeof(bitmap));
    MGUnitRect bounds = MGContentBounds(bitmap, 100, 100, 400); assert(bounds.width == 1 && bounds.height == 1); PASS();
    for (size_t y = 10; y < 90; y++) for (size_t x = 10; x < 90; x++) {
        size_t index = (y * 100 + x) * 4; bitmap[index] = bitmap[index + 1] = bitmap[index + 2] = 0;
    }
    bounds = MGContentBounds(bitmap, 100, 100, 400); assert(fabs(bounds.x - .08) < .001 && fabs(bounds.width - .84) < .001); PASS();
    memset(bitmap, 0, sizeof(bitmap)); bounds = MGContentBounds(bitmap, 100, 100, 400); assert(bounds.width == 1); PASS();
    assert(MGContentBounds(bitmap, 100, 100, 1).width == 1); PASS();
    // Property checks: mixed unknown/single/spread pages, viewport sizes and preferences.
    srand(143);
    for (unsigned iteration = 0; iteration < 5000; iteration++) {
        size_t count = 1 + rand() % 80; MGPageSize pages[80];
        for (size_t i = 0; i < count; i++) { int choice = rand() % 3; pages[i] = choice == 0 ? (MGPageSize){0, 0} : choice == 1 ? (MGPageSize){700, 1000} : (MGPageSize){1500, 1000}; }
        MGDirection direction = (MGDirection)(rand() % 3); double width = 300 + rand() % 900, height = 250 + rand() % 1000;
        p = MGMakePlan(pages, count, width, height, direction, rand() % 2, rand() % 2, rand() % 2, segments, groups, 200);
        assert(p.segmentCount >= count && p.segmentCount <= 2 * count && p.groupCount > 0);
        size_t covered = 0, pageCounts[80] = {0};
        for (size_t i = 0; i < p.groupCount; i++) {
            assert(groups[i].first == covered && (groups[i].count == 1 || groups[i].count == 2));
            for (size_t j = 0; j < groups[i].count; j++) { MGSegment segment = segments[covered + j]; assert(segment.source < count); pageCounts[segment.source]++; assert(MGFindGroup(segments, groups, p, segment.source, segment.half) == i); }
            covered += groups[i].count;
            assert(MGDisplayIndex(MGDisplayIndex(i, p.groupCount, direction), p.groupCount, direction) == i);
        }
        assert(covered == p.segmentCount);
        for (size_t i = 0; i < count; i++) assert(pageCounts[i] == 1 || pageCounts[i] == 2);
    }
    PASS();
    printf("Reader geometry: %u tests and 5,000 randomized layouts passed.\n", tests);
    return 0;
}
