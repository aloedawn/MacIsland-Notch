#include <libproc.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
extern int IsAppleInternalBuild(void);

static pthread_once_t identityOnce = PTHREAD_ONCE_INIT;
static bool isMenuBarAgent;
static void checkExecutable(void) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    isMenuBarAgent = proc_pidpath(getpid(), path, sizeof(path)) > 0 &&
        strcmp(path, "/System/Library/CoreServices/MenuBarAgent.app/Contents/MacOS/MenuBarAgent") == 0;
}
__attribute__((visibility("hidden"))) bool MacIslandIsMenuBarAgent(void) {
    pthread_once(&identityOnce, checkExecutable);
    return isMenuBarAgent;
}

static int fake_IsAppleInternalBuild(void) {
    if (MacIslandIsMenuBarAgent()) return 1;
    return IsAppleInternalBuild();
}
__attribute__((used)) static struct { const void *r; const void *o; } interposers[]
__attribute__((section("__DATA,__interpose"))) = {
    { (const void *)fake_IsAppleInternalBuild, (const void *)IsAppleInternalBuild },
};
