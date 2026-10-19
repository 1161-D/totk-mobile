#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include "../host/nvn_shader_math.h"

int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2 || argc==3 || (argc==4 && !strcmp(argv[2], "--export")));
    NSError *err=nil; id<MTLDevice> dev=MTLCreateSystemDefaultDevice(); assert(dev);
    NSString *source=[NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err]; assert(source);
    NSString *helpers=source;
    MTLCompileOptions *unchanged=nil;
    assert([zelda_shader_math(@"[[clang::optnone]] void unrelated() {}", &unchanged) isEqualToString:@"[[clang::optnone]] void unrelated() {}"] && !unchanged);
    NSString *body=@"\nkernel void pairs(device float4 *input [[buffer(0)]],device uint4 *output [[buffer(1)]],uint i [[thread_position_in_grid]]) { float4 v=input[i]; output[i]=as_type<uint4>(float4(spvFMul(v.x,v.y),spvFAdd(v.x,v.y),spvFSub(v.z,v.w),spvFAdd(spvFMul(v.x,v.y),v.z))); }\n"
      "kernel void chain(device float4 *input [[buffer(0)]],device uint4 *output [[buffer(1)]],uint i [[thread_position_in_grid]]) { float4 v=as_type<float4>(as_type<uint4>(input[i])&uint4(0x007fffff)|uint4(0x3f000000)); for(uint j=0;j<128;j++) v=spvFAdd(spvFMul(v,float4(0.999,0.998,0.997,0.996)),float4(0.0001,0.0002,0.0003,0.0004)); output[i]=as_type<uint4>(v); }\n";
    body=[body stringByAppendingString:@"kernel void matrix(device float4 *input [[buffer(0)]],device uint4 *output [[buffer(1)]],uint i [[thread_position_in_grid]]) { float4 v=input[i]; float2x2 a=float2x2(v.xy,v.zw), b=float2x2(v.zw,v.xy); float2x2 m=spvFMulMatrixMatrix(a,b); float2 x=spvFMulMatrixVector(m,v.xy), y=spvFMulVectorMatrix(v.zw,m); output[i]=as_type<uint4>(float4(x,y)); }\n"];
    if(argc==4) {
        MTLCompileOptions *options=nil;
        NSString *prepared=[zelda_shader_math(helpers, &options) stringByAppendingString:body];
        assert([prepared writeToFile:@(argv[3]) atomically:YES encoding:NSUTF8StringEncoding error:&err]);
        return 0;
    }
    id<MTLComputePipelineState> ps[2][3]; const char *names[]={"pairs","chain","matrix"};
    for(int mode=0;mode<2;mode++) {
        NSString *h=helpers; MTLCompileOptions *options=nil;
        if(mode || argc==3) h=zelda_shader_math(h, &options);
        id<MTLLibrary> lib;
        if(mode && argc==3) {
            NSData *data=[NSData dataWithContentsOfFile:@(argv[2])]; assert(data);
            dispatch_data_t bytes=dispatch_data_create(data.bytes,data.length,nil,^{ (void)data; });
            lib=[dev newLibraryWithData:bytes error:&err];
        } else lib=[dev newLibraryWithSource:[h stringByAppendingString:body] options:options error:&err];
        if(!lib) {fprintf(stderr,"%s\n",err.description.UTF8String);return 1;}
        for(int k=0;k<3;k++){ps[mode][k]=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@(names[k])] error:&err];assert(ps[mode][k]);}
    }
    const unsigned count=262144;
    id<MTLBuffer> input=[dev newBufferWithLength:count*16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output[2]={[dev newBufferWithLength:count*16 options:MTLResourceStorageModeShared],[dev newBufferWithLength:count*16 options:MTLResourceStorageModeShared]};
    uint32_t *p=input.contents,x=0x712ac394;
    for(unsigned i=0;i<count*4;i++){ x^=x<<13;x^=x>>17;x^=x<<5;p[i]=x; }
    const uint32_t edge[]={0,0x80000000,1,0x80000001,0x007fffff,0x00800000,0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,0x7fc00001,0x7fffffff,0x3f800001,0x3f800000,0xbf800000,0x3f7fffff};
    for(unsigned a=0;a<16;a++)for(unsigned b=0;b<16;b++){unsigned at=(a*16+b)*4;p[at]=edge[a];p[at+1]=edge[b];p[at+2]=edge[(a+7)%16];p[at+3]=edge[(b+11)%16];}
    id<MTLCommandQueue> queue=[dev newCommandQueue];
    for(int k=0;k<3;k++) {
      double times[2]={0,0};
      for(int rep=0;rep<6;rep++)for(int mode=0;mode<2;mode++) {
        id<MTLCommandBuffer> cb=[queue commandBuffer];id<MTLComputeCommandEncoder> e=[cb computeCommandEncoder];
        [e setComputePipelineState:ps[mode][k]];[e setBuffer:input offset:0 atIndex:0];[e setBuffer:output[mode] offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake(count,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];[e endEncoding];[cb commit];[cb waitUntilCompleted]; assert(!cb.error);
        if(rep)times[mode]+=(cb.GPUEndTime-cb.GPUStartTime)*1000/5;
      }
      uint32_t *a=output[0].contents,*b=output[1].contents;unsigned different=0,nan=0;
      for(unsigned i=0;i<count*4;i++)if(a[i]!=b[i]){float af,bf;memcpy(&af,a+i,4);memcpy(&bf,b+i,4);if(isnan(af)&&isnan(bf))nan++;else {if(different<5)printf("diff %s i=%u old=%08x new=%08x\n",names[k],i,a[i],b[i]);different++;}}
      assert(!different);
      printf("%s elements=%u differences=%u nan_payloads=%u %s_ms=%.3f %s_ms=%.3f\n",names[k],count*4,different,nan,
             argc==3?"runtime_source":"baseline",times[0],argc==3?"offline_binary":"safe_inline",times[1]);
    }
} }
