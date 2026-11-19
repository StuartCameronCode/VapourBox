#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
typedef const void *(*F)(int);
int main(int argc, char **argv) {
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 1; }
    F f = (F)dlsym(h, "getVSScriptAPI");
    for (int minor = 1; minor <= 4; minor++)
        printf("VSScript 4.%d -> %s\n", minor, f((4 << 16) | minor) ? "ok" : "NULL (refused)");
    return 0;
}
