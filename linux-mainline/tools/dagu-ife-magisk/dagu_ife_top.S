/*
 * Read-only IFE1 sampler for the Android board while the front
 * preview streams. Same ioremap prot / vermagic as dagu_ife_rd.S.
 *
 * Pass 0..PASSES-1 prints three lines per pass (A/B/C):
 *   A: 0x27f0 0x27f4 0x80 0x84 0x88 0x8c
 *   B: 0x9c 0xa0 0xa4 0xa8 0xac 0xb0
 *   C: 0xb4 0xb8 0xbc 0xc0 0x74 0x54
 * then, if FULL is set, one pass of 0x0000-0xd000 (4 words/line).
 * Nothing is written to the block.
 */
#ifndef PASSES
#define PASSES 96
#endif
#ifndef FULL
#define FULL 0
#endif
#ifndef MODNAME
#define MODNAME "dagu_ife_top"
#endif

.macro rd6 fmt o1 o2 o3 o4 o5 o6
	mov	x8, \o1
	ldr	w2, [x19, x8]
	mov	x8, \o2
	ldr	w3, [x19, x8]
	mov	x8, \o3
	ldr	w4, [x19, x8]
	mov	x8, \o4
	ldr	w5, [x19, x8]
	mov	x8, \o5
	ldr	w6, [x19, x8]
	mov	x8, \o6
	ldr	w7, [x19, x8]
	mov	w1, w21
	adr	x0, \fmt
	bl	printk
.endm

.section .init.text, "ax"
.globl init_module
.type init_module, %function
init_module:
	stp	x29, x30, [sp, #-64]!
	stp	x19, x20, [sp, #16]
	stp	x21, x22, [sp, #32]
	mov	x29, sp

	movz	x0, #0x3000
	movk	x0, #0x0acc, lsl #16
	movz	x1, #0xd000
	movz	x2, #0x0f07
	movk	x2, #0x0068, lsl #48
	bl	__ioremap
	cbz	x0, 1f
	mov	x19, x0

	mov	w21, wzr
10:
	rd6	fa, 0x27f0, 0x27f4, 0x80, 0x84, 0x88, 0x8c
	rd6	fb, 0x9c, 0xa0, 0xa4, 0xa8, 0xac, 0xb0
	rd6	fc, 0xb4, 0xb8, 0xbc, 0xc0, 0x74, 0x54
	/* ~1-3 ms spin so passes land on different frame phases */
	movz	x8, #0x0030, lsl #16
	add	x8, x8, x21, lsl #12
11:
	subs	x8, x8, #1
	b.ne	11b
	add	w21, w21, #1
	cmp	w21, #PASSES
	b.ne	10b

#if FULL
	mov	x22, xzr
20:
	ldr	w3, [x19, x22]
	add	x8, x22, #4
	ldr	w4, [x19, x8]
	add	x8, x22, #8
	ldr	w5, [x19, x8]
	add	x8, x22, #12
	ldr	w6, [x19, x8]
	mov	w2, w22
	mov	w1, wzr
	adr	x0, ff
	bl	printk
	add	x22, x22, #16
	mov	x8, #0xd000
	cmp	x22, x8
	b.ne	20b
#endif

	mov	x0, x19
	bl	__iounmap
	mov	w0, wzr
	b	4f
1:
	adr	x0, fe
	bl	printk
	mov	w0, #12
4:
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #64
	ret
	.align	2
fa:	.asciz	"dagu top A %u %08x %08x %08x %08x %08x %08x\n"
	.align	2
fb:	.asciz	"dagu top B %u %08x %08x %08x %08x %08x %08x\n"
	.align	2
fc:	.asciz	"dagu top C %u %08x %08x %08x %08x %08x %08x\n"
	.align	2
ff:	.asciz	"dagu full %u %05x %08x %08x %08x %08x\n"
	.align	2
fe:	.asciz	"dagu ife1 map fail\n"
.size init_module, .-init_module

.section .plt, "aw", %nobits
.space 16
.section .init.plt, "aw", %nobits
.space 16
.section .text.ftrace_trampoline, "aw", %nobits
.space 8

.section .exit.text, "ax"
.globl cleanup_module
.type cleanup_module, %function
cleanup_module:
	ret
.size cleanup_module, .-cleanup_module

.section .modinfo, "a"
.asciz	"license=GPL"
.asciz	"vermagic=4.19.157-perf-gb57830672689 SMP preempt mod_unload modversions aarch64"
.asciz	"name=" MODNAME
.asciz	"depends="

.macro	crcsym val name
	.quad	\val
	.asciz	"\name"
	.balign	64
.endm

.section __versions, "a"
	.balign	64
	crcsym	0xaad0c453, module_layout
	crcsym	0x7c32d0f0, printk
	crcsym	0x6b4b2933, __ioremap
	crcsym	0x45a55ec8, __iounmap

.section .gnu.linkonce.this_module, "aw"
	.align	6
.globl __this_module
__this_module:
	.space	0x18
	.asciz	MODNAME
	.org	__this_module + 0x170
	.quad	init_module
	.org	__this_module + 0x310
	.quad	cleanup_module
	.org	__this_module + 0x340
