#include <ntimage.h>

NTSYSAPI PVOID NTAPI RtlImageDirectoryEntryToData(_In_ PVOID base,
						  _In_ BOOLEAN mapped,
						  _In_ USHORT directory,
						  _Out_ PULONG size);
NTSYSAPI PVOID NTAPI RtlPcToFileHeader(_In_ PVOID pc, _Out_ PVOID *image);

/* Step into the calls that follow a successful WDI registration.
 * The miniport returns success and is then unloaded. These thunks record
 * the register status, each miniport callback, the PnP start status, and
 * the caller of unload.
 */
#define N_SLOTS 40
#define N_MODS 6

typedef UINT64 (*SLOT_FN)(UINT64, UINT64, UINT64, UINT64, UINT64, UINT64,
			  UINT64, UINT64);
typedef ULONG (*REG_FN)(PDRIVER_OBJECT, PUNICODE_STRING, PVOID, PVOID, PVOID,
			PVOID *);
typedef VOID (*DEREG_FN)(PVOID);
typedef NTSTATUS (*ADD_FN)(PDRIVER_OBJECT, PDEVICE_OBJECT);
typedef NTSTATUS (*PNP_FN)(PDEVICE_OBJECT, PIRP);
typedef VOID (*UNLOAD_FN)(PDRIVER_OBJECT);

struct TraceSlot {
	SLOT_FN orig;
	USHORT kind;
	USHORT off;
};

struct TraceMod {
	char tag[8];
	UINT64 base;
	UINT64 size;
};

static struct TraceSlot g_slot[N_SLOTS];
static int g_nslots;
static struct TraceMod g_mod[N_MODS];
static int g_nmod;
static UINT64 g_qc_base;
static UINT64 g_qc_size;
static REG_FN g_reg;
static DEREG_FN g_dereg;
static ADD_FN g_add;
static PNP_FN g_pnp;
static UNLOAD_FN g_qc_unload;
static BOOLEAN g_notify;
static LONG g_cb_logs;

static void put_hex(char *dst, UINT64 value, int nibbles)
{
	int i;

	for (i = nibbles - 1; i >= 0; i--) {
		UINT64 nyb = (value >> (i * 4)) & 0xf;
		*dst++ = (char)(nyb < 10 ? '0' + nyb : 'a' + (int)nyb - 10);
	}
	*dst = '\0';
}

static void remember_mod(const char *tag, UINT64 base, UINT64 size)
{
	int i, n;

	if (base == 0 || g_nmod >= N_MODS)
		return;
	for (i = 0; i < g_nmod; i++) {
		if (g_mod[i].base == base)
			return;
	}
	n = 0;
	while (tag[n] != '\0' && n < 7) {
		g_mod[g_nmod].tag[n] = tag[n];
		n++;
	}
	g_mod[g_nmod].tag[n] = '\0';
	g_mod[g_nmod].base = base;
	g_mod[g_nmod].size = size;
	g_nmod++;
}

static void log_where(const char *prefix, UINT64 pc)
{
	char line[80];
	const char *tag = "abs";
	UINT64 off = pc;
	int i, n;

	for (i = 0; i < g_nmod; i++) {
		if (dbg_ptr_in_image(pc, g_mod[i].base, g_mod[i].size)) {
			tag = g_mod[i].tag;
			off = pc - g_mod[i].base;
			break;
		}
	}
	n = 0;
	while (prefix[n] != '\0' && n < 40) {
		line[n] = prefix[n];
		n++;
	}
	i = 0;
	while (tag[i] != '\0' && n < 60) {
		line[n++] = tag[i++];
	}
	if (n < 70)
		line[n++] = '+';
	put_hex(line + n, off, 16);
	log_raw(line);
}

static void log_cb(int index, int entering, ULONG status)
{
	char line[64];
	int n = 0;
	const char *prefix = "hook cb ";

	while (prefix[n] != '\0') {
		line[n] = prefix[n];
		n++;
	}
	line[n++] = g_slot[index].kind == 2 ? 'w' : 'n';
	line[n++] = '+';
	put_hex(line + n, g_slot[index].off, 4);
	n += 4;
	if (entering) {
		const char *tail = " enter";
		int i = 0;
		while (tail[i] != '\0')
			line[n++] = tail[i++];
		line[n] = '\0';
	} else {
		const char *tail = " st=";
		int i = 0;
		while (tail[i] != '\0')
			line[n++] = tail[i++];
		put_hex(line + n, status, 8);
	}
	log_raw(line);
}

static void slot_enter(int index)
{
	if (InterlockedIncrement(&g_cb_logs) > 80)
		return;
	log_cb(index, 1, 0);
}

static void slot_exit(int index, ULONG status)
{
	if (g_cb_logs > 80)
		return;
	log_cb(index, 0, status);
}

#define SLOT_THUNK(n)                                                      \
	static UINT64 thunk_##n(UINT64 a0, UINT64 a1, UINT64 a2, UINT64 a3, \
				UINT64 a4, UINT64 a5, UINT64 a6, UINT64 a7) \
	{                                                                  \
		UINT64 st;                                                 \
		slot_enter(n);                                             \
		st = g_slot[n].orig(a0, a1, a2, a3, a4, a5, a6, a7);       \
		slot_exit(n, (ULONG)st);                                   \
		return st;                                                 \
	}

SLOT_THUNK(0)
SLOT_THUNK(1)
SLOT_THUNK(2)
SLOT_THUNK(3)
SLOT_THUNK(4)
SLOT_THUNK(5)
SLOT_THUNK(6)
SLOT_THUNK(7)
SLOT_THUNK(8)
SLOT_THUNK(9)
SLOT_THUNK(10)
SLOT_THUNK(11)
SLOT_THUNK(12)
SLOT_THUNK(13)
SLOT_THUNK(14)
SLOT_THUNK(15)
SLOT_THUNK(16)
SLOT_THUNK(17)
SLOT_THUNK(18)
SLOT_THUNK(19)
SLOT_THUNK(20)
SLOT_THUNK(21)
SLOT_THUNK(22)
SLOT_THUNK(23)
SLOT_THUNK(24)
SLOT_THUNK(25)
SLOT_THUNK(26)
SLOT_THUNK(27)
SLOT_THUNK(28)
SLOT_THUNK(29)
SLOT_THUNK(30)
SLOT_THUNK(31)
SLOT_THUNK(32)
SLOT_THUNK(33)
SLOT_THUNK(34)
SLOT_THUNK(35)
SLOT_THUNK(36)
SLOT_THUNK(37)
SLOT_THUNK(38)
SLOT_THUNK(39)

static SLOT_FN g_thunks[N_SLOTS] = {
	thunk_0,  thunk_1,  thunk_2,  thunk_3,  thunk_4,  thunk_5,  thunk_6,
	thunk_7,  thunk_8,  thunk_9,  thunk_10, thunk_11, thunk_12, thunk_13,
	thunk_14, thunk_15, thunk_16, thunk_17, thunk_18, thunk_19, thunk_20,
	thunk_21, thunk_22, thunk_23, thunk_24, thunk_25, thunk_26, thunk_27,
	thunk_28, thunk_29, thunk_30, thunk_31, thunk_32, thunk_33, thunk_34,
	thunk_35, thunk_36, thunk_37, thunk_38, thunk_39
};

static UINT64 take_slot(USHORT kind, USHORT off, SLOT_FN orig)
{
	int i = g_nslots;

	if (i >= N_SLOTS || orig == NULL)
		return (UINT64)orig;
	g_slot[i].orig = orig;
	g_slot[i].kind = kind;
	g_slot[i].off = off;
	g_nslots++;
	return (UINT64)g_thunks[i];
}

static void wrap_block(PVOID block, USHORT kind)
{
	USHORT size;
	ULONG i, n;
	PUINT64 words;

	if (block == NULL || g_qc_base == 0)
		return;
	size = *(USHORT *)((PUCHAR)block + 2);
	if (size < 8 || size > 0x200)
		return;
	words = (PUINT64)block;
	n = size / sizeof(UINT64);
	for (i = 0; i < n; i++) {
		if (!dbg_ptr_in_image(words[i], g_qc_base, g_qc_size))
			continue;
		words[i] = take_slot(kind, (USHORT)(i * 8), (SLOT_FN)words[i]);
	}
}

static VOID unload_thunk(_In_ PDRIVER_OBJECT driver)
{
	log_where("hook unload ", (UINT64)__builtin_return_address(0));
	if (g_qc_unload != NULL)
		g_qc_unload(driver);
}

/* ndis AddDevice at RVA 0x62f70 tails into a routine that calls the
 * function at RVA 0x10ccf0 and, when that function returns anything
 * other than zero, replaces the status with 0xc0000001. The hook
 * records the status before that replacement. */
#define NDIS_ADD_RVA 0x62f70u
#define NDIS_INNER_RVA 0x10ccf0u

static const UCHAR k_add_bytes[12] = {0x03, 0x00, 0x80, 0xd2, 0x02, 0x00,
				      0x80, 0xd2, 0xdc, 0x9b, 0xfe, 0x17};
static const UCHAR k_inner_bytes[16] = {0x7f, 0x23, 0x03, 0xd5, 0xfd, 0x7b,
					0xbd, 0xa9, 0xf3, 0x53, 0x01, 0xa9,
					0xf5, 0x13, 0x00, 0xf9};

typedef UINT32 (*inner_fn)(UINT64, UINT64);
static inner_fn g_inner;
static BOOLEAN g_inner_armed;

__attribute__((naked)) static void inner_tramp(void)
{
	__asm__ volatile("nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "nop\n\t"
			 "ret\n\t");
}

static UINT32 inner_hook(UINT64 block, UINT64 device)
{
	UINT32 status;
	char line[32];

	status = g_inner(block, device);
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'i';
	line[6] = 'n';
	line[7] = 'n';
	line[8] = 'e';
	line[9] = 'r';
	line[10] = ' ';
	line[11] = 's';
	line[12] = 't';
	line[13] = '=';
	put_hex(line + 14, status, 8);
	log_raw(line);
	return status;
}

static void flush_exec(_In_ void *dst, _In_ ULONG n)
{
	ULONG_PTR a = (ULONG_PTR)dst & ~(ULONG_PTR)63;
	ULONG_PTR end = ((ULONG_PTR)dst + n + 63) & ~(ULONG_PTR)63;

	for (; a < end; a += 64)
		__asm__ volatile("dc cvau, %0" ::"r"(a) : "memory");
	__asm__ volatile("dsb ish" ::: "memory");
	a = (ULONG_PTR)dst & ~(ULONG_PTR)63;
	for (; a < end; a += 64)
		__asm__ volatile("ic ivau, %0" ::"r"(a) : "memory");
	__asm__ volatile("dsb ish\n\tisb" ::: "memory");
}

static NTSTATUS write_exec(_In_ PVOID dst, _In_ const void *src, _In_ ULONG n)
{
	PMDL mdl;
	NTSTATUS status;

	mdl = IoAllocateMdl(dst, n, FALSE, FALSE, NULL);
	if (mdl == NULL)
		return STATUS_INSUFFICIENT_RESOURCES;
	MmBuildMdlForNonPagedPool(mdl);
	mdl->MappedSystemVa = dst;
	mdl->MdlFlags |= MDL_MAPPED_TO_SYSTEM_VA;
	status = MmProtectMdlSystemAddress(mdl, PAGE_EXECUTE_READWRITE);
	IoFreeMdl(mdl);
	if (!NT_SUCCESS(status))
		return status;
	RtlCopyMemory(dst, src, n);
	flush_exec(dst, n);
	return STATUS_SUCCESS;
}

static void arm_inner(_In_ PVOID add_fn)
{
	UINT64 base;
	UCHAR *inner;
	UCHAR detour[16];
	UCHAR tramp[32];
	NTSTATUS status;
	char line[40];

	if (g_inner_armed || add_fn == NULL)
		return;
	if (RtlPcToFileHeader(add_fn, (PVOID *)&base) == NULL || base == 0) {
		log_raw("hook inner base");
		return;
	}
	if ((UINT64)add_fn != base + NDIS_ADD_RVA ||
	    RtlCompareMemory(add_fn, k_add_bytes, sizeof(k_add_bytes)) !=
		    sizeof(k_add_bytes)) {
		log_where("hook inner at ", (UINT64)add_fn);
		return;
	}
	inner = (UCHAR *)(base + NDIS_INNER_RVA);
	if (RtlCompareMemory(inner, k_inner_bytes, sizeof(k_inner_bytes)) !=
	    sizeof(k_inner_bytes)) {
		log_raw("hook inner bytes");
		return;
	}
	RtlCopyMemory(tramp, inner, 16);
	*(UINT32 *)(tramp + 16) = 0x58000050;
	*(UINT32 *)(tramp + 20) = 0xd61f0200;
	*(UINT64 *)(tramp + 24) = (UINT64)(inner + 16);
	status = write_exec((PVOID)inner_tramp, tramp, sizeof(tramp));
	if (!NT_SUCCESS(status)) {
		line[0] = 'h';
		line[1] = 'o';
		line[2] = 'o';
		line[3] = 'k';
		line[4] = ' ';
		line[5] = 't';
		line[6] = 'r';
		line[7] = 'a';
		line[8] = 'm';
		line[9] = 'p';
		line[10] = '=';
		put_hex(line + 11, (ULONG)status, 8);
		log_raw(line);
		return;
	}
	g_inner = (inner_fn)inner_tramp;
	*(UINT32 *)detour = 0x58000050;
	*(UINT32 *)(detour + 4) = 0xd61f0200;
	*(UINT64 *)(detour + 8) = (UINT64)inner_hook;
	status = write_exec(inner, detour, sizeof(detour));
	if (!NT_SUCCESS(status)) {
		line[0] = 'h';
		line[1] = 'o';
		line[2] = 'o';
		line[3] = 'k';
		line[4] = ' ';
		line[5] = 'p';
		line[6] = 'a';
		line[7] = 't';
		line[8] = 'c';
		line[9] = 'h';
		line[10] = '=';
		put_hex(line + 11, (ULONG)status, 8);
		log_raw(line);
		return;
	}
	g_inner_armed = TRUE;
	remember_mod("ndis", base, 0x180000);
	log_raw("hook inner armed");
}

static NTSTATUS add_thunk(_In_ PDRIVER_OBJECT driver,
			  _In_ PDEVICE_OBJECT physical)
{
	NTSTATUS status;
	char line[32];

	log_raw("hook add enter");
	status = g_add(driver, physical);
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'a';
	line[6] = 'd';
	line[7] = 'd';
	line[8] = ' ';
	line[9] = 's';
	line[10] = 't';
	line[11] = '=';
	put_hex(line + 12, (ULONG)status, 8);
	log_raw(line);
	return status;
}

static NTSTATUS pnp_thunk(_In_ PDEVICE_OBJECT device, _In_ PIRP irp)
{
	UCHAR minor = 0xff;
	NTSTATUS status;
	char line[40];

	if (irp != NULL) {
		PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
		if (stack != NULL)
			minor = stack->MinorFunction;
	}
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'p';
	line[6] = 'n';
	line[7] = 'p';
	line[8] = ' ';
	put_hex(line + 9, minor, 2);
	line[11] = ' ';
	line[12] = 'e';
	line[13] = 'n';
	line[14] = 't';
	line[15] = 'e';
	line[16] = 'r';
	line[17] = '\0';
	log_raw(line);
	status = g_pnp(device, irp);
	line[11] = ' ';
	line[12] = 's';
	line[13] = 't';
	line[14] = '=';
	put_hex(line + 15, (ULONG)status, 8);
	log_raw(line);
	return status;
}

static void arm_driver(_In_ PDRIVER_OBJECT driver)
{
	PDRIVER_EXTENSION ext;

	if (driver == NULL)
		return;
	if (g_qc_unload == NULL &&
	    dbg_ptr_in_image((UINT64)driver->DriverUnload, g_qc_base, g_qc_size)) {
		g_qc_unload = driver->DriverUnload;
		driver->DriverUnload = unload_thunk;
		log_where("hook unload-fn ", (UINT64)g_qc_unload);
	}
	ext = driver->DriverExtension;
	if (ext != NULL && g_add == NULL && ext->AddDevice != NULL) {
		g_add = ext->AddDevice;
		ext->AddDevice = add_thunk;
		log_where("hook add-fn ", (UINT64)g_add);
		arm_inner(g_add);
	} else if (ext == NULL || ext->AddDevice == NULL) {
		log_raw("hook add-fn none");
	}
	if (g_pnp == NULL && driver->MajorFunction[IRP_MJ_PNP] != NULL &&
	    driver->MajorFunction[IRP_MJ_PNP] != pnp_thunk) {
		g_pnp = driver->MajorFunction[IRP_MJ_PNP];
		driver->MajorFunction[IRP_MJ_PNP] = pnp_thunk;
		log_where("hook pnp-fn ", (UINT64)g_pnp);
	}
}

static ULONG reg_thunk(_In_ PDRIVER_OBJECT driver,
		       _In_ PUNICODE_STRING path, _In_opt_ PVOID context,
		       _In_ PVOID ndis_chars, _In_ PVOID wdi_chars,
		       _Out_ PVOID *handle)
{
	ULONG status;
	char line[48];
	ULONG version = 0;

	if (wdi_chars != NULL)
		version = *(ULONG *)((PUCHAR)wdi_chars + 4);
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'r';
	line[6] = 'e';
	line[7] = 'g';
	line[8] = ' ';
	line[9] = 'v';
	line[10] = 'e';
	line[11] = 'r';
	line[12] = '=';
	put_hex(line + 13, version, 8);
	log_raw(line);
	wrap_block(ndis_chars, 1);
	wrap_block(wdi_chars, 2);
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'w';
	line[6] = 'r';
	line[7] = 'a';
	line[8] = 'p';
	line[9] = '=';
	put_hex(line + 10, (ULONG)g_nslots, 2);
	log_raw(line);
	status = g_reg(driver, path, context, ndis_chars, wdi_chars, handle);
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'r';
	line[6] = 'e';
	line[7] = 'g';
	line[8] = ' ';
	line[9] = 's';
	line[10] = 't';
	line[11] = '=';
	put_hex(line + 12, status, 8);
	log_raw(line);
	if (handle != NULL && *handle != NULL)
		log_where("hook handle ", (UINT64)*handle);
	else
		log_raw("hook handle none");
	arm_driver(driver);
	return status;
}

static VOID dereg_thunk(_In_ PVOID handle)
{
	log_where("hook dereg ", (UINT64)__builtin_return_address(0));
	g_dereg(handle);
	log_raw("hook dereg back");
}

static NTSTATUS write_qword(_In_ PVOID dst, _In_ UINT64 value)
{
	PMDL mdl;
	NTSTATUS status;

	mdl = IoAllocateMdl(dst, sizeof(value), FALSE, FALSE, NULL);
	if (mdl == NULL)
		return STATUS_INSUFFICIENT_RESOURCES;
	MmBuildMdlForNonPagedPool(mdl);
	mdl->MappedSystemVa = dst;
	mdl->MdlFlags |= MDL_MAPPED_TO_SYSTEM_VA;
	status = MmProtectMdlSystemAddress(mdl, PAGE_READWRITE);
	IoFreeMdl(mdl);
	if (!NT_SUCCESS(status)) {
		char line[40];

		line[0] = 'h';
		line[1] = 'o';
		line[2] = 'o';
		line[3] = 'k';
		line[4] = ' ';
		line[5] = 'p';
		line[6] = 'r';
		line[7] = 'o';
		line[8] = 't';
		line[9] = '=';
		put_hex(line + 10, (ULONG)status, 8);
		log_raw(line);
	}
	/* The import section is marked writable on disk, so the store is
	 * valid even when the protection call declines the view. */
	*(volatile UINT64 *)dst = value;
	return STATUS_SUCCESS;
}

static int name_is(const char *got, const char *want)
{
	int i;

	for (i = 0; want[i] != '\0'; i++) {
		char a = got[i];
		char b = want[i];
		if (a >= 'A' && a <= 'Z')
			a = (char)(a - 'A' + 'a');
		if (b >= 'A' && b <= 'Z')
			b = (char)(b - 'A' + 'a');
		if (a != b)
			return 0;
	}
	return got[i] == '\0';
}

static void hook_iat(_In_ PVOID base)
{
	ULONG size = 0;
	PIMAGE_IMPORT_DESCRIPTOR imp;
	NTSTATUS reg_st = STATUS_NOT_FOUND;
	NTSTATUS dereg_st = STATUS_NOT_FOUND;
	char line[48];

	imp = RtlImageDirectoryEntryToData(base, TRUE, IMAGE_DIRECTORY_ENTRY_IMPORT,
					   &size);
	if (imp == NULL) {
		log_raw("hook iat none");
		return;
	}
	for (; imp->Name != 0; imp++) {
		const char *dll = (const char *)((PUCHAR)base + imp->Name);
		PIMAGE_THUNK_DATA names;
		PIMAGE_THUNK_DATA slots;
		ULONG index;

		if (!name_is(dll, "NDIS.SYS") || imp->OriginalFirstThunk == 0 ||
		    imp->FirstThunk == 0)
			continue;
		names = (PIMAGE_THUNK_DATA)((PUCHAR)base + imp->OriginalFirstThunk);
		slots = (PIMAGE_THUNK_DATA)((PUCHAR)base + imp->FirstThunk);
		for (index = 0; names[index].u1.AddressOfData != 0; index++) {
			PIMAGE_IMPORT_BY_NAME ibn;
			UINT64 slot_addr;

			if (IMAGE_SNAP_BY_ORDINAL64(names[index].u1.Ordinal))
				continue;
			ibn = (PIMAGE_IMPORT_BY_NAME)((PUCHAR)base +
						      names[index].u1.AddressOfData);
			slot_addr = (UINT64)&slots[index].u1.Function;
			if (name_is((const char *)ibn->Name,
				    "NdisMRegisterWdiMiniportDriver")) {
				g_reg = (REG_FN)slots[index].u1.Function;
				reg_st = write_qword((PVOID)slot_addr, (UINT64)reg_thunk);
			} else if (name_is((const char *)ibn->Name,
					   "NdisMDeregisterWdiMiniportDriver")) {
				g_dereg = (DEREG_FN)slots[index].u1.Function;
				dereg_st = write_qword((PVOID)slot_addr,
						       (UINT64)dereg_thunk);
			}
		}
	}
	line[0] = 'h';
	line[1] = 'o';
	line[2] = 'o';
	line[3] = 'k';
	line[4] = ' ';
	line[5] = 'i';
	line[6] = 'a';
	line[7] = 't';
	line[8] = ' ';
	put_hex(line + 9, (ULONG)reg_st, 8);
	line[17] = ' ';
	put_hex(line + 18, (ULONG)dereg_st, 8);
	log_raw(line);
}

static BOOLEAN unicode_has(_In_opt_ PUNICODE_STRING name, _In_ const char *ascii)
{
	ULONG m = 0, n, i, j;

	if (name == NULL || name->Buffer == NULL)
		return FALSE;
	while (ascii[m] != '\0')
		m++;
	n = name->Length / sizeof(WCHAR);
	if (m == 0 || n < m)
		return FALSE;
	for (i = 0; i + m <= n; i++) {
		for (j = 0; j < m; j++) {
			WCHAR c = name->Buffer[i + j];
			char a = ascii[j];
			if (c >= L'A' && c <= L'Z')
				c = (WCHAR)(c - L'A' + L'a');
			if (a >= 'A' && a <= 'Z')
				a = (char)(a - 'A' + 'a');
			if (c != (WCHAR)a)
				break;
		}
		if (j == m)
			return TRUE;
	}
	return FALSE;
}

static VOID image_notify(_In_opt_ PUNICODE_STRING name, _In_ HANDLE process,
			 _In_ PIMAGE_INFO info)
{
	UINT64 base;
	UINT64 size;

	UNREFERENCED_PARAMETER(process);
	if (info == NULL || info->SystemModeImage == 0 || info->ImageBase == NULL)
		return;
	base = (UINT64)info->ImageBase;
	size = (UINT64)info->ImageSize;
	if (unicode_has(name, "qcwlan6800sc81.sys")) {
		g_qc_base = base;
		g_qc_size = size;
		remember_mod("qcwlan", base, size);
		log_where("hook img ", base);
		hook_iat(info->ImageBase);
	} else if (unicode_has(name, "ndis.sys")) {
		remember_mod("ndis", base, size);
		log_where("hook img ", base);
	} else if (unicode_has(name, "wdiwifi.sys")) {
		remember_mod("wdi", base, size);
		log_where("hook img ", base);
	}
}

static void trace_start(void)
{
	UNICODE_STRING routine;
	PVOID print_fn;
	PVOID nt_base = NULL;
	NTSTATUS status;

	RtlInitUnicodeString(&routine, L"DbgPrintEx");
	print_fn = MmGetSystemRoutineAddress(&routine);
	if (print_fn != NULL && RtlPcToFileHeader(print_fn, &nt_base) != NULL)
		remember_mod("nt", (UINT64)nt_base, 0x2000000);
	status = PsSetLoadImageNotifyRoutine(image_notify);
	g_notify = NT_SUCCESS(status);
	if (g_notify)
		log_raw("hook armed");
	else
		log_raw("hook notify failed");
}

static void trace_stop(void)
{
	if (g_notify)
		PsRemoveLoadImageNotifyRoutine(image_notify);
	g_notify = FALSE;
}
