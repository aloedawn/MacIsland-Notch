.text

.macro MI_WITNESS_TRAMPOLINE entry, slot_offset, callback
.p2align 2
.globl \entry
\entry:
    pacibsp
    stp x20, x19, [sp, #-32]!
    stp x29, x30, [sp, #16]
    add x29, sp, #16
    mov x19, x8
    adrp x16, _mi_saved_bodies@PAGE
    add x16, x16, _mi_saved_bodies@PAGEOFF
    ldr x16, [x16, #\slot_offset]
    blraaz x16
    mov x0, x20
    mov x1, x19
    bl \callback
    ldp x29, x30, [sp, #16]
    ldp x20, x19, [sp], #32
    retab
.endm

.macro MI_CLOCK_TRAMPOLINE entry, index, slot_offset
.p2align 2
.globl \entry
\entry:
    pacibsp
    stp x20, x19, [sp, #-32]!
    stp x29, x30, [sp, #16]
    add x29, sp, #16
    mov x19, x8
    adrp x16, _mi_saved_bodies@PAGE
    add x16, x16, _mi_saved_bodies@PAGEOFF
    ldr x16, [x16, #\slot_offset]
    blraaz x16
    mov w0, #\index
    mov x1, x20
    mov x2, x19
    bl _mi_clock_body_result
    ldp x29, x30, [sp, #16]
    ldp x20, x19, [sp], #32
    retab
.endm

MI_WITNESS_TRAMPOLINE _mi_surface_body, 0, _mi_music_surface_result
MI_CLOCK_TRAMPOLINE _mi_clock_body_1, 1, 8
MI_CLOCK_TRAMPOLINE _mi_clock_body_2, 2, 16
MI_CLOCK_TRAMPOLINE _mi_clock_body_3, 3, 24
MI_CLOCK_TRAMPOLINE _mi_clock_body_4, 4, 32
MI_CLOCK_TRAMPOLINE _mi_clock_body_5, 5, 40
MI_CLOCK_TRAMPOLINE _mi_clock_body_6, 6, 48
