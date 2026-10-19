#include "hle_vi.c"
#include "kernel.h"

uint32_t front_vsync_handle(void);

HLE_FORCE("_ZN2nn2vi20GetDisplayVsyncEventEPNS_2os15SystemEventTypeEPNS0_7DisplayE",
          "Host display refresh signals a real auto-clear kernel event", Result, h_vi_Vsync,
          void *event, void *display) {
    if (!event || display != &g_display) return 0x202;
    uint32_t handle = front_vsync_handle();
    if (!handle) return 0xce01;
    void (*attach)(void *, uint32_t, int, int) = guest_sym(
        "_ZN2nn2os33AttachReadableHandleToSystemEventEPNS0_15SystemEventTypeEjbNS0_14EventClearModeE");
    if (!attach) die("missing SDK SystemEvent attachment");
    attach(event, handle, 1, 1);
    return RES_OK;
}
