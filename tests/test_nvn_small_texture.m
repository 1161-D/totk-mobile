#import <Foundation/Foundation.h>
#include <assert.h>
#include <sys/mman.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include "nvn_obj.h"
#include "nvn_dirty.h"

static int (*fault_hook)(void *,int,void *);
static void (*write_hook)(void *,size_t);
void dm_fault_hook_register(int (*fn)(void *,int,void *)) { fault_hook=fn; }
void dm_guest_write_prep_register(void (*fn)(void *,size_t)) { write_hook=fn; }
void dm_guest_write_prepare(void *p,size_t n) { write_hook(p,n); }
@interface NvPkg : NSObject { @public NSData *small_bytes; uint64_t stamp,seen; const uint8_t *z_alias; uint8_t z_alias_known,z_alias_bad; } @end
// One aliased virtual pool, as nvn_virtual.inc maps it.
static uint8_t *alias_virtual,*alias_physical; static size_t alias_size;
uint64_t nvn_canonical_address(uint64_t address,uint64_t length) {
    uint64_t start=(uintptr_t)alias_virtual,end=start+alias_size;
    if (!alias_virtual || address>=end || address+length<=start) return address;
    return address>=start && address+length<=end ? (uintptr_t)alias_physical+address-start : 0;
}
@implementation NvPkg @end
#define MLOG(...) ((void)0)
#include "../host/nvn_small_texture.inc"
int main(void) { @autoreleasepool {
    size_t page=(size_t)getpagesize();
    uint8_t *memory=mmap(NULL,page*2,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(memory!=MAP_FAILED);
    memset(memory,0x37,page*2);nvn_dirty_add_range(memory,page*2);assert(fault_hook&&write_hook);
    tex_t texture={.mem=memory,.L={.size=64}};NvPkg *package=[NvPkg new];
    nvn_dirty_protect(memory,64);package->stamp=package->seen=nvn_dirty_now();
    zelda_small_texture_snapshot(package,&texture);assert(package->small_bytes.length==64);
    dm_guest_write_prepare(memory+128,1);memory[128]++;
    assert(nvn_dirty_since(memory,64,package->stamp));
    assert(zelda_small_texture_unchanged(package,&texture,0));
    assert(!nvn_dirty_since(memory,64,package->stamp));
    dm_guest_write_prepare(memory+4,1);memory[4]++;
    assert(!zelda_small_texture_unchanged(package,&texture,0));
    // Larger textures copy only their two shared boundary-page portions, never their full interior.
    uint8_t *large=mmap(NULL,page*5,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(large!=MAP_FAILED);
    memset(large,0x4b,page*5);nvn_dirty_add_range(large,page*5);
    tex_t big={.mem=large+page/4,.L={.size=page*3+page/2}};NvPkg *boundary=[NvPkg new];
    zelda_texture_protect(&big);boundary->stamp=nvn_dirty_now();
    z_texture_edge_reuse=0;zelda_reuploaded_texture_snapshot(boundary,&big);assert(!boundary->small_bytes);
    z_texture_edge_reuse=1;zelda_reuploaded_texture_snapshot(boundary,&big);assert(boundary->small_bytes.length==page*3/2);
    dm_guest_write_prepare(large,1);large[0]++;
    assert(zelda_small_texture_unchanged(boundary,&big,0));
    dm_guest_write_prepare(large+page*4-1,1);large[page*4-1]++;
    assert(zelda_small_texture_unchanged(boundary,&big,0));
    for(unsigned k=0;k<3;k++) {
        size_t position=k==0?page/4+1:k==1?page+1:page*4-page/4-1;
        dm_guest_write_prepare(large+position,1);large[position]++;
        assert(!zelda_small_texture_unchanged(boundary,&big,0));
        zelda_texture_protect(&big);boundary->stamp=nvn_dirty_now();zelda_reuploaded_texture_snapshot(boundary,&big);
        assert(boundary->small_bytes.length==page*3/2);
    }
    assert(!zelda_small_texture_unchanged(boundary,&big,1));
    tex_t aligned={.mem=large+page,.L={.size=page*2}};
    zelda_texture_protect(&aligned);boundary->stamp=nvn_dirty_now();zelda_reuploaded_texture_snapshot(boundary,&aligned);
    assert(!boundary->small_bytes);nvn_dirty_remove_range(large);assert(!munmap(large,page*5));
    assert(nvn_dirty_since(memory,64,package->stamp));
    zelda_small_texture_snapshot(package,&texture);assert(!package->small_bytes);
    nvn_dirty_protect(memory,64);package->stamp=nvn_dirty_now();
    zelda_small_texture_snapshot(package,&texture);assert(package->small_bytes);
    zelda_reuploaded_texture_snapshot(package,&texture);assert(package->small_bytes);  // default limit keeps one page
    assert(zelda_small_texture_unchanged(package,&texture,0));
    assert(!zelda_small_texture_unchanged(package,&texture,1));
    texture.L.size=16385;zelda_small_texture_snapshot(package,&texture);assert(!package->small_bytes);
    texture.L.size=64;nvn_dirty_remove_range(memory);
    zelda_small_texture_snapshot(package,&texture);assert(!package->small_bytes);
    assert(!zelda_small_texture_unchanged(package,&texture,0));
    // A texture in an aliased virtual pool is dirty when either mapping is written.
    mach_vm_address_t alias=0; vm_prot_t current,maximum;
    assert(!mach_vm_remap(mach_task_self(),&alias,page*2,0,VM_FLAGS_ANYWHERE,mach_task_self(),(uintptr_t)memory,FALSE,&current,&maximum,VM_INHERIT_NONE));
    alias_virtual=(uint8_t *)(uintptr_t)alias;alias_physical=memory;alias_size=page*2;
    nvn_dirty_add_range(memory,page*2);nvn_dirty_add_range(alias_virtual,page*2);
    tex_t aliased={.mem=alias_virtual,.L={.size=64}};NvPkg *other=[NvPkg new];
    zelda_texture_protect(&aliased);other->stamp=other->seen=nvn_dirty_now();
    assert(zelda_texture_tracked(other,&aliased) && !zelda_texture_dirty_since(other,&aliased,other->stamp));
    dm_guest_write_prepare(memory+8,1);memory[8]++;
    assert(zelda_texture_dirty_since(other,&aliased,other->stamp) && alias_virtual[8]==memory[8]);
    zelda_texture_protect(&aliased);other->stamp=nvn_dirty_now();
    assert(!zelda_texture_dirty_since(other,&aliased,other->stamp));
    dm_guest_write_prepare(alias_virtual+8,1);alias_virtual[8]++;
    assert(zelda_texture_dirty_since(other,&aliased,other->stamp));
    aliased.L.size=page+64;zelda_texture_protect(&aliased);other->stamp=nvn_dirty_now();
    zelda_reuploaded_texture_snapshot(other,&aliased);assert(other->small_bytes.length==64);
    dm_guest_write_prepare(memory+page+128,1);memory[page+128]++;
    assert(zelda_small_texture_unchanged(other,&aliased,0));
    dm_guest_write_prepare(memory+16,1);memory[16]++;
    assert(!zelda_small_texture_unchanged(other,&aliased,0));
    tex_t straddling={.mem=alias_virtual+page*2-32,.L={.size=64}};NvPkg *edge=[NvPkg new];
    assert(!zelda_texture_tracked(edge,&straddling));
    nvn_dirty_remove_range(alias_virtual);nvn_dirty_remove_range(memory);
    assert(!munmap(alias_virtual,page*2));
    assert(!munmap(memory,page*2));
    puts("Texture exact bytes: bounded shared-page edges, interior writes, neighbours, re-arming, actual changes, stale snapshots and aliases passed");
} }
