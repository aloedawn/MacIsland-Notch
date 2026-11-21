#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <ptrauth.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/sysctl.h>

#include "supported-builds.h"

extern const void *swift_getGenericMetadata(
    uintptr_t request, const void *const *arguments, const void *description);

static atomic_bool mi_allow_unverified = false;

static bool allow_unverified_from_env(void) {
    const char *raw = getenv("MACISLAND_ALLOW_UNVERIFIED_BUILD");
    if (!raw) return false;
    while (*raw == ' ' || *raw == '\t' || *raw == '\n' || *raw == '\r') raw++;
    size_t len = strlen(raw);
    while (len > 0 && (raw[len - 1] == ' ' || raw[len - 1] == '\t' ||
                       raw[len - 1] == '\n' || raw[len - 1] == '\r')) {
        len--;
    }
    return (len == 1 && raw[0] == '1') ||
           (len == 4 && strncasecmp(raw, "true", 4) == 0) ||
           (len == 3 && strncasecmp(raw, "yes", 3) == 0);
}

void mi_set_allow_unverified_build(int allow) {
    atomic_store(&mi_allow_unverified, allow != 0);
}

bool mi_is_supported_build(void) {
    if (atomic_load(&mi_allow_unverified) || allow_unverified_from_env()) return true;
    char build[64] = {0};
    size_t size = sizeof(build);
    if (sysctlbyname("kern.osversion", build, &size, NULL, 0) != 0) return false;
    static const char *const supported[] = { MACISLAND_SUPPORTED_BUILDS_LIST };
    for (size_t i = 0; i < sizeof(supported) / sizeof(supported[0]); i++) {
        if (strcmp(build, supported[i]) == 0) return true;
    }
    return false;
}

bool mi_is_writable_region(const void *address, size_t bytes) {
    if (!address || bytes == 0) return false;
    mach_vm_address_t start = (mach_vm_address_t)(uintptr_t)address;
    mach_vm_address_t region = start;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    kern_return_t kr = mach_vm_region(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64,
                                      (vm_region_info_t)&info, &count, &obj);
    if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
    return kr == KERN_SUCCESS && (info.protection & VM_PROT_WRITE) != 0 &&
           region <= start && (mach_vm_size_t)bytes <= size - (start - region);
}

static const uint8_t *auth_vwt(const void *metadata) {
    const void *const *slot = ((const void *const *)metadata) - 1;
    const void *vwt = *slot;
#if __has_feature(ptrauth_calls)
    // Swift SpecialPointerAuthDiscriminators::ValueWitnessTable = 0x2e3f.
    vwt = ptrauth_auth_data(
        vwt, ptrauth_key_asda, ptrauth_blend_discriminator(slot, 0x2e3f));
#endif
    return (const uint8_t *)vwt;
}

uintptr_t move_signed(uintptr_t *from, uintptr_t *to, uint32_t disc) {
#if __has_feature(ptrauth_calls)
    void *before = (void *)*from;
    void *after = ptrauth_auth_and_resign(
        before, ptrauth_key_asia, ptrauth_blend_discriminator(from, disc),
        ptrauth_key_asia, ptrauth_blend_discriminator(to, disc));
    return (uintptr_t)after;
#else
    (void)to;
    (void)disc;
    return *from;
#endif
}

const void *mi_call_metadata_accessor(const void *raw_fn, uintptr_t request) {
#if __has_feature(ptrauth_calls)
    const void *(*fn)(uintptr_t) = ptrauth_sign_unauthenticated(
        raw_fn, ptrauth_key_function_pointer, 0);
#else
    const void *(*fn)(uintptr_t) = (const void *(*)(uintptr_t))raw_fn;
#endif
    return fn(request);
}

const void *mi_get_generic_metadata(
    uintptr_t request, const void *const *arguments, const void *raw_description) {
#if __has_feature(ptrauth_calls)
    // Swift SpecialPointerAuthDiscriminators::TypeDescriptor = 0xae86.
    const void *description = ptrauth_sign_unauthenticated(
        raw_description, ptrauth_key_asda, 0xae86);
#else
    const void *description = raw_description;
#endif
    return swift_getGenericMetadata(request, arguments, description);
}

size_t mi_type_layout_size(const void *metadata) {
    const uint8_t *vwt = auth_vwt(metadata);
    return *(const size_t *)(vwt + 0x40);
}

bool mi_is_optional_some(const void *enum_addr, const void *wrapped_metadata) {
    if (!enum_addr || !wrapped_metadata) return false;
    const uint8_t *vwt = auth_vwt(wrapped_metadata);
    const void *const *fn_slot = (const void *const *)(vwt + 0x30);
#if __has_feature(ptrauth_calls)
    // Swift SpecialPointerAuthDiscriminators::GetEnumTagSinglePayload = 0x60f0.
    unsigned (*get_tag)(const void *, unsigned, const void *) = ptrauth_auth_and_resign(
        (void *)*fn_slot, ptrauth_key_asia, ptrauth_blend_discriminator(fn_slot, 0x60f0),
        ptrauth_key_function_pointer, 0);
#else
    unsigned (*get_tag)(const void *, unsigned, const void *) =
        (unsigned (*)(const void *, unsigned, const void *))*fn_slot;
#endif
    return get_tag(enum_addr, 1, wrapped_metadata) == 0;
}

#ifdef MACISLAND_TESTING
extern const void *swift_getTypeByMangledNameInContext2(
    const char *typeNameStart, size_t typeNameLength,
    const void *context, const void *const *genericArgs);

const void *mi_get_type_by_mangled_name(const char *start, size_t len) {
    if (!start || len == 0) return NULL;
    return swift_getTypeByMangledNameInContext2(start, len, NULL, NULL);
}

void mi_store_optional_tag(void *enum_addr, unsigned which_case, const void *wrapped_metadata) {
    if (!enum_addr || !wrapped_metadata) return;
    const uint8_t *vwt = auth_vwt(wrapped_metadata);
    const void *const *fn_slot = (const void *const *)(vwt + 0x38);
#if __has_feature(ptrauth_calls)
    // Swift SpecialPointerAuthDiscriminators::StoreEnumTagSinglePayload = 0xa0d1.
    void (*store_tag)(void *, unsigned, unsigned, const void *) = ptrauth_auth_and_resign(
        (void *)*fn_slot, ptrauth_key_asia, ptrauth_blend_discriminator(fn_slot, 0xa0d1),
        ptrauth_key_function_pointer, 0);
#else
    void (*store_tag)(void *, unsigned, unsigned, const void *) =
        (void (*)(void *, unsigned, unsigned, const void *))*fn_slot;
#endif
    store_tag(enum_addr, which_case, 1, wrapped_metadata);
}
#endif

extern void mi_surface_body(void);
extern void mi_clock_body_1(void);
extern void mi_clock_body_2(void);
extern void mi_clock_body_3(void);
extern void mi_clock_body_4(void);
extern void mi_clock_body_5(void);
extern void mi_clock_body_6(void);

static void (*const mi_witness_entries[7])(void) = {
    mi_surface_body,
    mi_clock_body_1,
    mi_clock_body_2,
    mi_clock_body_3,
    mi_clock_body_4,
    mi_clock_body_5,
    mi_clock_body_6,
};

__attribute__((visibility("hidden"))) uintptr_t mi_saved_bodies[7];

uintptr_t mi_prepare_witness_body(uint32_t index, uintptr_t *slot, uint32_t discriminator) {
    if (index >= 7) return 0;
    void (*entry)(void) = mi_witness_entries[index];
#if __has_feature(ptrauth_calls)
    uintptr_t context = ptrauth_blend_discriminator(slot, discriminator);
    mi_saved_bodies[index] = (uintptr_t)ptrauth_auth_and_resign(
        (void *)*slot, ptrauth_key_asia, context, ptrauth_key_function_pointer, 0);
    return (uintptr_t)ptrauth_auth_and_resign(
        entry, ptrauth_key_function_pointer, 0, ptrauth_key_asia, context);
#else
    (void)discriminator;
    mi_saved_bodies[index] = *slot;
    return (uintptr_t)entry;
#endif
}
