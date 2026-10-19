// Resource-dependent check of the real SDK writer -> target -> queued host bridge.
#define main probe_main
#include "../host/probe.c"
#undef main
#include "../host/codec.c"
#include "../host/vibration.h"
#include <assert.h>
#include <math.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    char *load[] = {argv[0], argv[1], "--load-only"};
    assert(!probe_main(3, load)); initialize_guest(); alarm(20);
    void (*writer_ctor)(void *) = guest_sym("_ZN2nn3hid15VibrationWriterC1Ev");
    void (*target_ctor)(void *) = guest_sym("_ZN2nn3hid15VibrationTargetC1Ev");
    void (*connection_ctor)(void *) = guest_sym("_ZN2nn3hid23VibrationNodeConnectionC1Ev");
    unsigned (*connect)(void *, void *, void *) = guest_sym("_ZN2nn3hid23VibrationNodeConnection7ConnectEPNS0_13VibrationNodeES3_");
    void (*disconnect)(void *) = guest_sym("_ZN2nn3hid23VibrationNodeConnection10DisconnectEv");
    void (*set_handle)(void *, const uint32_t *) = guest_sym("_ZN2nn3hid15VibrationTarget24SetVibrationDeviceHandleERKNS0_21VibrationDeviceHandleE");
    void (*write_value)(void *, const ZeldaVibrationValue *) = guest_sym("_ZN2nn3hid15VibrationWriter5WriteERKNS0_14VibrationValueE");
    void (*update)(void) = guest_sym("_ZN2nn3hid13VibrationNode6UpdateEv");
    assert(writer_ctor && target_ctor && connection_ctor && connect && disconnect && set_handle && write_value && update);
    // These v1.4.3 objects fit below 0x100; retain a guard after each opaque object.
    _Alignas(16) unsigned char writers[2][0x120], targets[2][0x120], links[2][0x120];
    memset(writers,0xa5,sizeof writers); memset(targets,0xa5,sizeof targets); memset(links,0xa5,sizeof links);
    uint32_t handles[2]; assert(vibration_handles(handles,2,0,1)==2);
    vibration_active(true); vibration_permit(true);
    for (int i=0;i<2;i++) {
        writer_ctor(writers[i]); target_ctor(targets[i]); connection_ctor(links[i]);
        set_handle(targets[i],&handles[i]); assert(connect(links[i],writers[i],targets[i])==1);
    }
    ZeldaVibrationValue values[2]={{.2f,160,.3f,320},{.7f,180,.1f,350}}, out[2];
    for (int step=0;step<5;step++) {
        if (step==1) vibration_permit(false);
        if (step==2) { vibration_permit(true); vibration_active(false); }
        if (step==3) vibration_active(true);
        if (step==4) values[0]=values[1]=(ZeldaVibrationValue){0,160,0,320};
        for (int i=0;i<2;i++) write_value(writers[i],&values[i]);
        update(); vibration_take(out);
        for (int i=0;i<2;i++) {
            float low=step==1 || step==2 ? 0 : values[i].low_amplitude;
            float high=step==1 || step==2 ? 0 : values[i].high_amplitude;
            fprintf(stderr,"VIBRATION_SDK step=%d channel=%d low=%.3f/%.1f high=%.3f/%.1f\n",step,i,
                out[i].low_amplitude,out[i].low_frequency,out[i].high_amplitude,out[i].high_frequency);
            assert(fabsf(out[i].low_amplitude-low)<1e-6f && fabsf(out[i].high_amplitude-high)<1e-6f);
        }
    }
    for (int i=0;i<2;i++) {
        disconnect(links[i]);
        for (unsigned j=0x100;j<0x120;j++) assert(writers[i][j]==0xa5 && targets[i][j]==0xa5 && links[i][j]==0xa5);
    }
    alarm(0);
    puts("Real SDK vibration: two writers, targets, queued sends, flush, permission, focus reset and silence passed; no physical output tested");
}
