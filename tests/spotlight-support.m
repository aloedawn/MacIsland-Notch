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
    int first = mi_spotlight_patch();
    int second = mi_spotlight_patch();
    printf("before=%d patch=%d repeat=%d after=%d\n", before, first, second, supports());
    return first == 1 && second == 1 && supports() ? 0 : 1;
}
