/* Load a libdvdread by path, DVDOpen a disc folder, then report whether
 * libdvdcss can be found by its leaf name with RTLD_NOLOAD.
 * Run under DYLD_PRINT_LIBRARIES=1 to see which libdvdcss (if any) loaded.
 *
 *   cc -o dlopen-harness dlopen-harness.c
 *   DYLD_PRINT_LIBRARIES=1 ./dlopen-harness path/to/libdvdread.dylib Tests/TestResources/dvd_titles
 */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: %s LIBDVDREAD DVD_DIR\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("load fail: %s\n", dlerror()); return 1; }
    void *(*open_)(const char *) = (void *(*)(const char *))dlsym(h, "DVDOpen");
    void (*close_)(void *) = (void (*)(void *))dlsym(h, "DVDClose");
    void *d = open_(argv[2]);
    printf("DVDOpen=%p\n", d);
    if (d) close_(d);
    void *css = dlopen("libdvdcss.2.dylib", RTLD_NOLOAD);
    printf("libdvdcss found by leaf name with RTLD_NOLOAD: %s\n", css ? "yes" : "no");
    return 0;
}
