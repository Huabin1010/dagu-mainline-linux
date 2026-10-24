/*
 * Read IFE1 while the front camera is streaming. Do not call this
 * from boot: the block clock is off and a read can stall the bus.
 * Page protection is the value audio_wcd9xxx.ko passes to __ioremap
 * on this 4.19.157 kernel.
 *
 * One window, twelve passes. x19 is the mapped base.
 * Words are read only. Nothing is written to a clear register.
 */
.macro dump_window id start end
	mov	w21, wzr
10\@:
	mov	x22, \start
20\@:
	ldr	w4, [x19, x22]
	add	x8, x22, #4
	ldr	w5, [x19, x8]
	add	x8, x22, #8
	ldr	w6, [x19, x8]
	add	x8, x22, #12
	ldr	w7, [x19, x8]
	mov	w1, w21
	mov	w2, \id
	mov	w3, w22
	adr	x0, 3f
	bl	printk
	add	x22, x22, #16
	mov	x8, \end
	cmp	x22, x8
	b.ne	20\@b
	movz	x8, #0x9999
	movk	x8, #0x1999, lsl #16
11\@:
	subs	x8, x8, #1
	bne	11\@b
	add	w21, w21, #1
	cmp	w21, #12
	b.ne	10\@b
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
	dump_window 12, 0x5400, 0x6300
	dump_window 5, 0xb200, 0xb400
	mov	x0, x19
	bl	__iounmap
	mov	w0, wzr
	b	4f
1:
	adr	x0, 5f
	bl	printk
	mov	w0, #12
4:
	ldp	x21, x22, [sp, #32]
	ldp	x19, x20, [sp, #16]
	ldp	x29, x30, [sp], #64
	ret
	.align	2
3:
	.asciz	"dagu blk %u %u %03x %08x %08x %08x %08x\n"
	.align	2
5:
	.asciz	"dagu ife1 map fail\n"
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
.asciz	"name=dagu_ife_rd"
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
	.asciz	"dagu_ife_rd"
	.space	0x170 - 0x18 - 12
	.quad	init_module
	.space	0x310 - 0x178
	.quad	cleanup_module
	.space	0x340 - 0x318
