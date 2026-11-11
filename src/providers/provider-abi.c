#include <ptrauth.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

extern const void *swift_getGenericMetadata(
    uintptr_t request, const void *const *arguments, const void *description);

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
    const void *const *slot = ((const void *const *)metadata) - 1;
    const void *vwt = *slot;
#if __has_feature(ptrauth_calls)
    // Swift SpecialPointerAuthDiscriminators::ValueWitnessTable = 0x2e3f.
    vwt = ptrauth_auth_data(
        vwt, ptrauth_key_asda, ptrauth_blend_discriminator(slot, 0x2e3f));
#endif
    return *(const size_t *)((const uint8_t *)vwt + 0x40);
}

bool mi_is_optional_some(const void *enum_addr, const void *wrapped_metadata) {
    if (!enum_addr || !wrapped_metadata) return false;
    const void *const *slot = ((const void *const *)wrapped_metadata) - 1;
    const void *vwt = *slot;
#if __has_feature(ptrauth_calls)
    vwt = ptrauth_auth_data(
        vwt, ptrauth_key_asda, ptrauth_blend_discriminator(slot, 0x2e3f));
    const void *const *fn_slot = (const void *const *)((const uint8_t *)vwt + 0x30);
    // Swift SpecialPointerAuthDiscriminators::GetEnumTagSinglePayload = 0x60f0.
    unsigned (*get_tag)(const void *, unsigned, const void *) = ptrauth_auth_and_resign(
        (void *)*fn_slot, ptrauth_key_asia, ptrauth_blend_discriminator(fn_slot, 0x60f0),
        ptrauth_key_function_pointer, 0);
#else
    const void *const *fn_slot = (const void *const *)((const uint8_t *)vwt + 0x30);
    unsigned (*get_tag)(const void *, unsigned, const void *) =
        (unsigned (*)(const void *, unsigned, const void *))*fn_slot;
#endif
    return get_tag(enum_addr, 1, wrapped_metadata) == 0;
}

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
