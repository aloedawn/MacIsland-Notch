#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdbool.h>
#import <stdio.h>
#include "spotlight.m"

extern void mi_set_allow_unverified_build(int allow);

void mi_surface_body(void) {}
void mi_clock_body_1(void) {}
void mi_clock_body_2(void) {}
void mi_clock_body_3(void) {}
void mi_clock_body_4(void) {}
void mi_clock_body_5(void) {}
void mi_clock_body_6(void) {}

int main(void) {
    if (!mi_is_supported_build()) { fprintf(stderr, "supported build rejected\n"); return 1; }
    mi_set_allow_unverified_build(1);
    if (!mi_is_supported_build()) { fprintf(stderr, "allow unverified build failed\n"); return 1; }
    mi_set_allow_unverified_build(0);
    if (!mi_is_supported_build()) { fprintf(stderr, "supported build rejected after reset\n"); return 1; }

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
