#ifndef DR_PRIVATE_BRIDGE_H
#define DR_PRIVATE_BRIDGE_H
#include <stdint.h>
#include <CoreGraphics/CoreGraphics.h>
int DRBridgeAvailable(void);
int DRMoveWindowsToSpace(const uint32_t *windows, int count, uint64_t space);
int DRAddWindowToSpaces(uint32_t window, const uint64_t *spaces, int count);
int DRMoveSpaceToDisplay(uint64_t space, const char *display, int index);
uint64_t DRCreateSpace(void);
int DRDestroySpace(uint64_t space);
int DRSelectSpace(const char *display, uint64_t space);
#endif
