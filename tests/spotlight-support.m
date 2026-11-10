#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>
#include "spotlight.m"

int main(void) {
    if (mi_spotlight_enable() != -1) { fprintf(stderr, "enabled outside Siri AI\n"); return 1; }
    if (!dlopen("/System/Library/PrivateFrameworks/CampoUIInternal.framework/CampoUIInternal", RTLD_NOW)) {
        fprintf(stderr, "CampoUIInternal unavailable\n"); return 1;
    }
    bool (*supports)(void) = (bool (*)(void))dlsym(RTLD_DEFAULT, "CampoDeviceSupportsCenterHUD");
    bool before = supports();
    int result = mi_spotlight_patch();
    printf("before=%d patch=%d after=%d\n", before, result, supports());
    return result == 1 && supports() ? 0 : 1;
}
