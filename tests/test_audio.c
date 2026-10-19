#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include "../host/audio_mixer.c"
#include "../host/audio_output.inc"

void dm_guest_write_prepare(void *address, size_t size) { (void)address; (void)size; }
static uint8_t packet[16384], status[32];
static uint32_t header[16];
static uint8_t *voice_parameters, *effect_parameters, *split_parameters, *mix_parameters;
static struct { int16_t pcm[1200], coefficients[16], context[3]; float pcm_float[1200]; uint8_t adpcm[32], auxiliary[8192]; } memory;

static void setup(void) {
    audio_mixer_close(); memset(&memory, 0, sizeof memory); memset(packet, 0, sizeof packet);
    const uint32_t configuration[13] = {48000,240,4,1,2,1,1,0,1,2,4,0,0x3f564552};
    assert(audio_mixer_open(configuration)); audio_mixer_volume(1);
    uint32_t h[16] = {0x3f564552,16,9*32,2*0x188,2*0x70,0xc0,32+2*0x930,0x140,16,32};
    memcpy(header, h, sizeof h); header[15] = 64;
    for (unsigned i = 1; i < 15; i++) header[15] += header[i];
    memcpy(packet, header, 64);
    pool pool_parameter = {.address=(uintptr_t)&memory,.size=sizeof memory,.state=4};
    memcpy(packet + 80, &pool_parameter, sizeof pool_parameter);
    channel ch = {.id=0,.volume={1,0},.used=1};
    size_t at = 80 + header[2]; memcpy(packet + at, &ch, sizeof ch); at += header[4];
    voice_parameters = packet + at; at += header[3]; effect_parameters = packet + at; at += header[5];
    split_parameters = packet + at; uint32_t magic = 0x48444e53; memcpy(split_parameters, &magic, 4); at += header[9];
    mix_parameters = packet + at; uint32_t count = 2; memcpy(mix_parameters + 4, &count, 4); at += 32;
    mix final = {.volume=1,.rate=48000,.count=2,.used=1,.id=0,.destination=UNUSED_MIX,.splitter=UINT32_MAX};
    mix sub = final; sub.id=1; sub.volume=.5f; sub.destination=0; sub.matrix[0][0]=sub.matrix[1][1]=1;
    memcpy(packet + at, &final, sizeof final); memcpy(packet + at + sizeof final, &sub, sizeof sub); at += 2 * sizeof final;
    packet[at]=1; packet[at+1]=1; count=2; memcpy(packet+at+0x120,&count,4); packet[at+0x125]=1;
    voice_parameters[8]=voice_parameters[9]=1; voice_parameters[11]=2;
    uint32_t rate=48000, one=1; float gain=1;
    memcpy(voice_parameters+12,&rate,4); memcpy(voice_parameters+24,&one,4);
    memcpy(voice_parameters+28,&gain,4); memcpy(voice_parameters+32,&gain,4); memcpy(voice_parameters+0x54,&one,4);
    memcpy(voice_parameters+0x70,&one,4); uint32_t no_split=UINT32_MAX; memcpy(voice_parameters+0x74,&no_split,4);
    audio_wave waves[4] = {{.address=(uintptr_t)memory.pcm,.size=960,.end=480},{.sent=1},{.sent=1},{.sent=1}};
    memcpy(voice_parameters+0x78,waves,sizeof waves);
}
static void sent(void) {
    voice_parameters[8]=0;
    for (unsigned i=0;i<4;i++) voice_parameters[0x78+i*0x38+26]=1;
}
static void check_pcm_and_routes(void) {
    setup(); for (unsigned i=0;i<480;i++) memory.pcm[i]=1000;
    assert(audio_mixer_update(packet,header,0,status));
    struct { float samples[480]; uint32_t guard; } out = {.guard=0xdeadbeef};
    assert(audio_mixer_render(1,out.samples));
    assert(out.guard==0xdeadbeef && fabsf(out.samples[478]-500.0f/32768)<1e-7f && out.samples[479]==0);
    sent(); assert(audio_mixer_update(packet,header,1,status)); assert(u64(status)==240 && audio_u32(status+8)==0);
    voice_parameters[10]=2; assert(audio_mixer_update(packet,header,1,status));
    assert(audio_mixer_render(2,out.samples)); assert(out.samples[478]==0);
    assert(audio_mixer_update(packet,header,2,status) && u64(status)==240);
    voice_parameters[10]=0; assert(audio_mixer_update(packet,header,2,status));
    assert(audio_mixer_render(3,out.samples)); assert(audio_mixer_update(packet,header,3,status));
    assert(u64(status)==480 && audio_u32(status+8)==1 && wave_bytes==0);
    // A cyclic mix graph must fail instead of replaying feedback forever.
    uint32_t one=1; memcpy(mix_parameters+32+sizeof(mix)+0x924,&one,4);
    assert(!audio_mixer_update(packet,header,3,status));
}
static void check_adpcm(void) {
    setup(); voice_parameters[11]=6;
    uint64_t address=(uintptr_t)memory.coefficients,size=32;
    memcpy(voice_parameters+0x60,&address,8);memcpy(voice_parameters+0x68,&size,8);
    uint8_t encoded[10]={0,0x12,0x34,0x56,0x78,0x9a,0xbc,0xde,0,0x12}; memcpy(memory.adpcm,encoded,10);
    audio_wave w={.address=(uintptr_t)memory.adpcm,.size=10,.end=16}; memcpy(voice_parameters+0x78,&w,sizeof w);
    assert(audio_mixer_update(packet,header,0,status));
    const int expected[16]={1,2,3,4,5,6,7,-8,-7,-6,-5,-4,-3,-2,1,2};
    for(unsigned i=0;i<16;i++){float sample[6]={0};assert(source_sample(&sources[0],sample));assert(sample[0]==expected[i]);}
    assert(sources[0].cursor.consumed==1 && wave_bytes==0);
    // A non-frame-aligned start restores the supplied prediction history, including on loops.
    memory.coefficients[0]=2048; memory.context[1]=100; w.start=1;w.end=3;w.loop=1;w.loops=1;
    w.context=(uintptr_t)memory.context;w.context_size=6;
    memcpy(voice_parameters+0x78,&w,sizeof w);assert(audio_mixer_update(packet,header,0,status));
    const int looped[4]={102,105,102,105};
    for(unsigned i=0;i<4;i++){float sample[6]={0};assert(source_sample(&sources[0],sample));assert(sample[0]==looped[i]);}
    w.address=1;memcpy(voice_parameters+0x78,&w,sizeof w);assert(!audio_mixer_update(packet,header,0,status));
}
static void check_splitters(void) {
    setup();for(unsigned i=0;i<480;i++)memory.pcm[i]=1000;
    uint8_t parameters[272]={0};uint32_t words[8]={0x48444e53,2,1};memcpy(parameters,words,32);
    uint32_t empty[7]={0x49444e53,0,48000,0,0,0,0};memcpy(parameters+32,empty,sizeof empty);
    uint32_t connection[8]={0x49444e53,1,48000,1,0,0,0,0};memcpy(parameters+60,connection,sizeof connection);
    destination d={.magic=0x44444e53,.id=0,.volume={0,1},.mix=1,.used=1};memcpy(parameters+92,&d,sizeof d);
    assert(update_splitters(parameters,sizeof parameters));
    assert(!update_splitters(parameters,259));
    uint32_t no_mix=UNUSED_MIX,split=1;memcpy(voice_parameters+0x70,&no_mix,4);memcpy(voice_parameters+0x74,&split,4);
    assert(audio_mixer_update(packet,header,0,status));float out[480];assert(audio_mixer_render(1,out));
    assert(out[478]==0 && fabsf(out[479]-500.0f/32768)<1e-7f);
}
static void check_float_and_pitch(void) {
    setup();voice_parameters[11]=5;uint32_t two=2,one=1;
    memcpy(voice_parameters+24,&two,4);memcpy(voice_parameters+0x15c,&one,4);
    channel right={.id=1,.volume={0,1},.used=1};memcpy(packet+80+header[2]+sizeof(channel),&right,sizeof right);
    for(unsigned i=0;i<480;i++){memory.pcm_float[i*2]=.25f;memory.pcm_float[i*2+1]=-.5f;}
    audio_wave wave={.address=(uintptr_t)memory.pcm_float,.size=480*8,.end=480};memcpy(voice_parameters+0x78,&wave,sizeof wave);
    assert(audio_mixer_update(packet,header,0,status));float out[480];assert(audio_mixer_render(1,out));
    assert(fabsf(out[478]-.125f)<1e-7f && fabsf(out[479]+.25f)<1e-7f);
    setup();for(unsigned i=0;i<480;i++)memory.pcm[i]=(int16_t)i;
    float pitch=.5f;memcpy(voice_parameters+28,&pitch,4);assert(audio_mixer_update(packet,header,0,status));
    assert(audio_mixer_render(1,out));sent();assert(audio_mixer_update(packet,header,1,status));assert(u64(status)==120);
    pitch=2;memcpy(voice_parameters+28,&pitch,4);assert(audio_mixer_update(packet,header,1,status));
    assert(audio_mixer_render(2,out));assert(audio_mixer_update(packet,header,2,status));assert(u64(status)==480 && audio_u32(status+8)==1);
    setup();assert(audio_mixer_update(packet,header,0,status));assert(wave_bytes==960);
    sent();voice_parameters[10]=1;assert(audio_mixer_update(packet,header,0,status));
    assert(!wave_bytes && audio_u32(status+8)==1);
}
static void check_filters_effects(void) {
    biquad b={.enabled=1,.b={.5f,0,0},.a={.5f,0}};filter_state state={0};
    assert(filter_sample(1,&b,&state)==.5f);assert(filter_sample(0,&b,&state)==.25f);
    setup(); voice_parameters[9]=0;assert(audio_mixer_update(packet,header,0,status));
    // Limiter's delayed output stays within its configured threshold for a sustained overload.
    limiter_parameters limiter={.count=1,.input={0},.output={0},.delay_min=4,.delay_max=8,.attack=1,.release=1,.threshold=.5f,.input_gain=1,.output_gain=1};
    for(unsigned n=0;n<240;n++)mix_buffer(0,0)[n]=32767;
    assert(limiter_effect(0,(const uint8_t*)&limiter,true,0));
    for(unsigned n=4;n<240;n++)assert(fabsf(mix_buffer(0,0)[n]-16383.5f)<.01f);
    effects[0]=7;effects[2]=1;
    struct { uint8_t bytes[0x90]; uint32_t guard; } effect_status={.guard=0xdeadbeef};
    audio_mixer_effect_status(effect_status.bytes);
    assert(effect_status.bytes[0]==3 && effect_status.guard==0xdeadbeef);
    assert(f32(effect_status.bytes+16)==1 && f32(effect_status.bytes+40)==.5f);
    effects[2]=0;audio_mixer_effect_status(effect_status.bytes);assert(effect_status.bytes[0]==4);
    // AUX returns use sample rings and must not overwrite the CPU-owned header.
    uint8_t parameter[160]={0};parameter[24]=1;uint32_t channels_n=1,rate=48000,capacity=480;
    uint64_t send=(uintptr_t)memory.auxiliary,receive=send+4096;
    memcpy(parameter+48,&channels_n,4);memcpy(parameter+52,&rate,4);memcpy(parameter+56,&capacity,4);
    memcpy(parameter+64,&send,8);memcpy(parameter+80,&receive,8);
    uint32_t position=400;memcpy(memory.auxiliary+0x44,&position,4);memcpy(memory.auxiliary+4096+0x40,&position,4);
    memset(memory.auxiliary,0xa5,0x40);
    for(unsigned n=0;n<480;n++){int32_t value=300+n;memcpy(memory.auxiliary+4096+0x80+n*4,&value,4);}
    for(unsigned n=0;n<240;n++)mix_buffer(0,0)[n]=n;
    assert(auxiliary_effect(parameter,true,0));
    assert(audio_u32(memory.auxiliary+0x44)==160 && audio_u32(memory.auxiliary)==0xa5a5a5a5);
    assert(mix_buffer(0,1)[0]==700 && mix_buffer(0,1)[80]==300);
    // A wet-only impulse produces a finite, nonzero reverb tail after its delay.
    free_effect(&effect_states[0]);
    reverb_parameters reverb={.input={0},.output={1},.count=1,.rate=48000,.room_hf=-2000,.hf_reference=5000,
        .decay=1,.hf_ratio=.7f,.room_gain=-1000,.diffusion=60,.reflection_delay=.01f,.reverb_delay=.01f,.density=60};
    double energy=0;for(unsigned frame=0;frame<100;frame++){
        memset(mix_buffer(0,0),0,240*sizeof(float));if(!frame)mix_buffer(0,0)[0]=1000;
        assert(reverb_effect(0,(const uint8_t*)&reverb,true,0));
        for(unsigned n=0;n<240;n++){float value=mix_buffer(0,1)[n];assert(isfinite(value));energy+=value*value;}
    }assert(energy>1);
}
enum { QUEUE_FRAMES=100000 };
static void *produce(void *unused) {
    (void)unused;
    for(uint32_t i=0;i<QUEUE_FRAMES;i++){
        while(atomic_load(&audio_write_cursor)-atomic_load(&audio_read_cursor)==AUDIO_RING_FRAMES)sched_yield();
        float pair[2]={(float)i,-(float)i};audio_output_push(pair,1);
    }return NULL;
}
static void check_queue(void) {
    setenv("DM_AUDIO","0",1);assert(audio_output_open(48000));
    atomic_store(&audio_read_cursor,UINT32_MAX-50);atomic_store(&audio_write_cursor,UINT32_MAX-50);
    pthread_t producer;assert(!pthread_create(&producer,NULL,produce,NULL));
    for(uint32_t i=0;i<QUEUE_FRAMES;i++){
        while(atomic_load(&audio_write_cursor)==atomic_load(&audio_read_cursor))sched_yield();
        float pair[2];audio_output_pull(pair,1);assert(pair[0]==i && pair[1]==-(float)i);
    }pthread_join(producer,NULL);assert(!audio_overruns);
    float silence[8];memset(silence,0xa5,sizeof silence);
    AudioBufferList buffers={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=sizeof silence,.mData=silence}}};
    assert(audio_output_callback(NULL,NULL,NULL,0,4,&buffers)==noErr);
    for(unsigned i=0;i<8;i++)assert(silence[i]==0);
    float loud[2]={1,-1};audio_output_push(loud,1);audio_output_push(loud,1);
    audio_mute(true);assert(audio_muted());
    float muted[4];memset(muted,0xa5,sizeof muted);uint32_t before=atomic_load(&audio_read_cursor);
    AudioBufferList quiet={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=2,.mDataByteSize=sizeof muted,.mData=muted}}};
    assert(audio_output_callback(NULL,NULL,NULL,0,2,&quiet)==noErr);
    assert(atomic_load(&audio_read_cursor)-before==2);for(unsigned i=0;i<4;i++)assert(muted[i]==0);
    audio_mute(false);assert(!audio_muted());
    audio_output_close();
}
int main(void) {
    check_pcm_and_routes();check_adpcm();check_splitters();check_float_and_pitch();check_filters_effects();check_queue();audio_mixer_close();
    puts("Audio decode, routing, effects, lifecycle and 100000-frame queue checks passed");
}
