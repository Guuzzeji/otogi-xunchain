/*
 * Linux only: what xboxrecomp's left-out files provide and Otogi never uses.
 * The framebuffer window (video/fb_present*.c, RECOMP_FB_WINDOW) is a debug
 * view of guest RAM; the game draws through src/gl_hle.zig. Mouse and
 * keyboard merging (input/mkb_input.c) is Win32 raw input; src/input.zig
 * reads keys and pads through SDL3.
 */
#include <stdint.h>

void xbox_FramebufferWindowStart(void) {}
void xbox_FramebufferWindowSet(uint32_t fb_va, uint32_t pitch) { (void)fb_va; (void)pitch; }
void xbox_FramebufferWindowSetAA(uint32_t sy) { (void)sy; }
void xbox_FramebufferWindowPresent(uint32_t fb_va, uint32_t pitch) { (void)fb_va; (void)pitch; }
void xbox_FramebufferWindowSetTitle(const uint16_t *name, int max_chars) { (void)name; (void)max_chars; }
void xbox_FramebufferWindowFrameStats(uint32_t draws) { (void)draws; }
int mkb_merge(uint32_t port, void *state) { (void)port; (void)state; return 0; }
