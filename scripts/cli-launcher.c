/* A compatibility entry point only. Credentials belong to the bundled CLI. */
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc;
    uint32_t length = 0;
    (void)_NSGetExecutablePath(NULL, &length);
    if (length == 0 || length > 1024 * 1024) {
        fputs("ParaAir could not locate its CLI launcher.\n", stderr);
        return 126;
    }
    char *image = malloc(length);
    char resolved[PATH_MAX];
    if (image == NULL || _NSGetExecutablePath(image, &length) != 0 || realpath(image, resolved) == NULL) {
        free(image);
        fputs("ParaAir could not resolve its CLI launcher.\n", stderr);
        return 126;
    }
    free(image);
    char *basename = strrchr(resolved, '/');
    if (basename == NULL) {
        fputs("ParaAir has an invalid CLI launcher path.\n", stderr);
        return 126;
    }
    *basename = '\0';
    char target[PATH_MAX];
    int written = snprintf(target, sizeof(target), "%s/ParaAirCLI.app/Contents/MacOS/paraair", resolved);
    if (written < 0 || (size_t)written >= sizeof(target)) {
        fputs("ParaAir CLI bundle path is too long.\n", stderr);
        return 126;
    }
    argv[0] = target;
    execv(target, argv);
    fputs("ParaAir could not start its bundled CLI. Check that the complete app is installed.\n", stderr);
    return 126;
}
