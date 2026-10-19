#include "../host/filesystem.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

static local_file *open_file(const char *path, unsigned mode) {
    local_file *file = NULL;
    assert(!filesystem_path(0, 8, path, NULL, mode, &file, NULL) && file);
    return file;
}
static void check_contents(const char *expected) {
    char data[5] = {0}; uint64_t count;
    local_file *file = open_file("/slot/data", 1);
    assert(!filesystem_file(file, 0, 0, data, 4, &count) && count == 4 && !memcmp(data, expected, 4));
    filesystem_close(file);
}
int main(void) {
    char temp[] = "work/tmp/filesystem.XXXXXX";
    assert(mkdtemp(temp)); int original = open(".", O_RDONLY); assert(original >= 0);
    assert(!chdir(temp) && !mkdir("work", 0700));
    uint64_t cache_size;
    assert(filesystem_cache_info(0, &cache_size) == 0x202);
    assert(filesystem_mount(FILESYSTEM_CACHE_BASE) == 0x202);
    assert(filesystem_cache_create(FILESYSTEM_CACHE_COUNT, 1024, 1024));
    assert(!filesystem_cache_create(0, 1024, 1024));
    assert(filesystem_cache_create(0, 1024, 1024) == 0x402);
    assert(!filesystem_cache_info(0, &cache_size) && cache_size == 1024);
    assert(!filesystem_mount(FILESYSTEM_CACHE_BASE));
    assert(filesystem_cache_delete(0));
    assert(!filesystem_path(FILESYSTEM_CACHE_BASE, 0, "/cached", NULL, 4, NULL, NULL));
    local_file *cached = NULL;
    assert(!filesystem_path(FILESYSTEM_CACHE_BASE, 8, "/cached", NULL, 3, &cached, NULL));
    assert(!filesystem_file(cached, 1, 0, "keep", 4, NULL)); filesystem_close(cached);
    assert(!filesystem_commit(FILESYSTEM_CACHE_BASE));
    assert(!filesystem_path(FILESYSTEM_CACHE_BASE, 1, "/cached", NULL, 0, NULL, NULL));
    filesystem_shutdown();
    assert(!filesystem_cache_info(0, &cache_size) && cache_size == 1024);
    assert(!filesystem_mount(FILESYSTEM_CACHE_BASE));
    assert(!filesystem_path(FILESYSTEM_CACHE_BASE, 8, "/cached", NULL, 1, &cached, NULL));
    char cache_data[4]; uint64_t read_size;
    assert(!filesystem_file(cached, 0, 0, cache_data, 4, &read_size) && read_size == 4 && !memcmp(cache_data, "keep", 4));
    filesystem_unmount(FILESYSTEM_CACHE_BASE); // Open files retain the mounted transaction.
    assert(filesystem_cache_delete(0)); filesystem_close(cached);
    assert(!filesystem_cache_delete(0) && filesystem_cache_info(0, &cache_size) == 0x202);
    assert(!unlink("work/cache-0.lock"));
    assert(!filesystem_mount(0) && !filesystem_mount(1));
    assert(!filesystem_path(0, 2, "/slot", NULL, 0, NULL, NULL));
    assert(!filesystem_path(0, 0, "/slot/data", NULL, 4, NULL, NULL));
    assert(filesystem_path(0, 0, "/slot/data", NULL, 4, NULL, NULL) == 0x402);
    assert(filesystem_path(0, 8, "/Slot/data", NULL, 1, NULL, NULL) == 0x202);
    uint64_t type; assert(!filesystem_path(0, 7, "/slot", NULL, 0, NULL, &type) && !type);
    local_file *file = open_file("/slot/data", 3); uint64_t size;
    assert(!filesystem_file(file, 4, 0, NULL, 0, &size) && size == 4);
    assert(!filesystem_file(file, 1, 0, "good", 4, NULL));
    assert(filesystem_commit(0)); // An open writer must not be committed.
    filesystem_close(file); assert(!filesystem_commit(0));
    file = open_file("/slot/data", 3);
    assert(!filesystem_file(file, 1, 0, "bad!", 4, NULL)); filesystem_close(file);
    filesystem_shutdown(); assert(!filesystem_mount(0)); check_contents("good"); // Uncommitted writes roll back.
    assert(!symlink("../..", "work/save.work/escape"));
    assert(filesystem_path(0, 0, "/escape/outside", NULL, 4, NULL, NULL));
    assert(filesystem_path(0, 0, "/../outside", NULL, 4, NULL, NULL));
    assert(access("outside", F_OK)); assert(!unlink("work/save.work/escape"));
    assert(!filesystem_path(0, 5, "/slot/data", "/slot/renamed", 0, NULL, NULL));
    assert(filesystem_path(0, 7, "/slot/data", NULL, 0, NULL, &type) == 0x202);
    assert(!filesystem_path(0, 5, "/slot/renamed", "/slot/data", 0, NULL, NULL));
    file = open_file("/slot/data", 3);
    assert(filesystem_file(file, 1, 4, "x", 1, NULL)); // No append permission; failed writes poison this transaction.
    assert(filesystem_file(file, 0, UINT64_MAX, NULL, 0, &size));
    filesystem_close(file); assert(filesystem_commit(0));
    filesystem_shutdown(); assert(!filesystem_mount(0)); check_contents("good");
    assert(!filesystem_path(0, 1, "/slot/data", NULL, 0, NULL, NULL));
    assert(!filesystem_path(0, 3, "/slot", NULL, 0, NULL, NULL));
    assert(!filesystem_commit(0)); filesystem_shutdown();
    assert(!rmdir("work/save") && !unlink("work/save.lock") && !unlink("work/temporary.lock") && !rmdir("work"));
    assert(!fchdir(original)); close(original); assert(!rmdir(temp));
    puts("filesystem persistence, rollback, bounds and path confinement checks passed");
}
