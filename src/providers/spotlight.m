#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <ptrauth.h>
#import <stdatomic.h>
#import <stdint.h>
#import <string.h>
#import <sys/sysctl.h>

// Spotlight's island is gated per device, not per display. On hardware Apple
// ships with a CenterHUD aperture, CampoDeviceSupportsCenterHUD() is true and
// Siri AI only grows Spotlight out of a display that MenuBarAgent configured
// with a cutout; every other display comes up detached as ordinary Spotlight.
// On a notched Mac the function is false, so Campo falls back to a simulated
// cutout on every display and abandons the search when the menu bar refuses
// the cutout on an external monitor. Setting the function's cached answer
// inside Siri AI selects Apple's hardware path without changing global
// MobileGestalt answers or hooking any method.
//
// On 26C5035r the cached fast path is:
//   adrp x8, sOnce@PAGE;  ldr x8, [x8, sOnce@PAGEOFF]; cmn x8, #1; b.ne slow
//   adrp x8, sSupports@PAGE; ldrb w0, [x8, sSupports@PAGEOFF]; ret
static atomic_int state;

static uintptr_t adrpPage(uint32_t insn, uintptr_t pc) {
    uint64_t imm = (((uint64_t)((insn >> 5) & 0x7ffff) << 2) | ((insn >> 29) & 3));
    int64_t offset = ((int64_t)(imm << 43)) >> 31;  // sign-extend 21 bits, then scale by 4 KiB
    return (pc & ~(uintptr_t)0xfff) + (uintptr_t)offset;
}

static bool isWritableByte(uintptr_t address) {
    mach_vm_address_t region = address;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    return kr == KERN_SUCCESS && (info.protection & VM_PROT_WRITE) != 0 &&
           region <= address && address + 1 <= region + size;
}

int mi_spotlight_patch(void) {
    void *symbol = dlsym(RTLD_DEFAULT, "CampoDeviceSupportsCenterHUD");
    if (!symbol) return -2;
    bool (*supports)(void) = (bool (*)(void))symbol;
    bool original = supports();  // completes the dispatch_once initialiser
    const uint32_t *code = ptrauth_strip(symbol, ptrauth_key_function_pointer);
    uintptr_t pc = (uintptr_t)code;
    if ((code[0] & 0x9f00001f) != 0x90000008 ||      // adrp x8
        (code[1] & 0xffc003ff) != 0xf9400108 ||      // ldr x8, [x8, #imm]
        code[2] != 0xb100051f ||                     // cmn x8, #1
        code[3] != 0x54000081 ||                     // b.ne +16
        (code[4] & 0x9f00001f) != 0x90000008 ||      // adrp x8
        (code[5] & 0xffc003ff) != 0x39400100 ||      // ldrb w0, [x8, #imm]
        code[6] != 0xd65f03c0)                       // ret
        return -3;
    uintptr_t address = adrpPage(code[4], pc + 16) + ((code[5] >> 10) & 0xfff);
    if (!isWritableByte(address)) return -6;
    volatile uint8_t *cached = (volatile uint8_t *)address;
    if (*cached != (uint8_t)original) return -4;
    *cached = 1;
    return supports() ? 1 : -5;
}

int mi_spotlight_enable(void) {
    char build[64] = {0};
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) || strcmp(build, "26C5035r") ||
        ![NSBundle.mainBundle.executablePath isEqualToString:@"/System/Applications/Siri AI.app/Contents/MacOS/Siri AI"])
        return -1;
    atomic_store(&state, mi_spotlight_patch());
    return 0;
}

int mi_spotlight_status(void) { return atomic_load(&state); }
