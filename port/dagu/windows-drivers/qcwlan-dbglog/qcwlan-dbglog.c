/* SPDX-License-Identifier: MIT
 * Capture DbgPrintEx from the QCA6390 miniport into a file.
 *
 * qcwlan6800sc81.sys reads MPGlobalDebugLevel, MPGlobalDebugComponents,
 * and GlobalDebugLogOutput from the miniport configuration key. When the
 * output value is 1 it calls DbgPrintEx with component 0x50 (IHVNETWORK)
 * and level 0. Boot options are NODEBUG, so those lines otherwise have
 * no consumer. This driver registers the kernel debug-print callback and
 * appends the matching lines to \SystemRoot\Temp\qcwlan-dbg.log.
 *
 * The callback may run at HIGH_LEVEL, so it only copies into a nonpaged
 * ring. A system thread writes the file at PASSIVE_LEVEL.
 */
#include <ntddk.h>
#include "match.h"
#include "range.h"
#include "ring.h"

#define RING_CAP (1024u * 1024u)
#define LINE_MAX 480u

static DbgRing g_ring;
static UCHAR *g_storage;
static volatile LONG g_lock;
static KEVENT g_stop;
static PETHREAD g_thread;
static BOOLEAN g_callback;

static void lock_acquire(void)
{
	while (InterlockedCompareExchange(&g_lock, 1, 0) != 0)
		YieldProcessor();
}

static void lock_release(void)
{
	InterlockedExchange(&g_lock, 0);
}

static void log_raw(const char *text)
{
	char line[200];
	ULONG n = 0;

	if (g_storage == NULL || text == NULL)
		return;
	while (text[n] != '\0' && n < sizeof(line) - 2) {
		line[n] = text[n];
		n++;
	}
	line[n++] = '\n';
	lock_acquire();
	(void)dbg_ring_push(&g_ring, line, n);
	lock_release();
}

static ULONG body_len(_In_ PSTRING output)
{
	ULONG n = output->Length;

	if (n > 400)
		n = 400;
	return n;
}

static VOID debug_print_callback(_In_ PSTRING Output, _In_ ULONG ComponentId,
				 _In_ ULONG Level)
{
	char line[LINE_MAX];
	ULONG n, body, i;
	int wrote;

	if (Output == NULL || Output->Buffer == NULL || Output->Length == 0)
		return;
	if (ComponentId != 0x50 && ComponentId != 0x4d &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "WDI") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "wlan") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "WLAN") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "miniport") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "Miniport") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "firmware") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "PBL") &&
	    !dbg_text_has(Output->Buffer, body_len(Output), "SBL"))
		return;
	body = Output->Length;
	if (body > 400)
		body = 400;
	wrote = 0;
	line[wrote++] = 'c';
	line[wrote++] = '=';
	for (i = 0; i < 2; i++) {
		UCHAR nyb = (UCHAR)((ComponentId >> (4 * (1 - i))) & 0xf);
		line[wrote++] = (char)(nyb < 10 ? '0' + nyb : 'a' + nyb - 10);
	}
	line[wrote++] = ' ';
	line[wrote++] = 'l';
	line[wrote++] = '=';
	line[wrote++] = (char)('0' + (Level % 10));
	line[wrote++] = ' ';
	for (i = 0; i < body && (ULONG)wrote < LINE_MAX - 2; i++) {
		char c = Output->Buffer[i];
		if (c == '\0')
			break;
		line[wrote++] = c;
	}
	if (wrote == 0 || line[wrote - 1] != '\n')
		line[wrote++] = '\n';
	n = (ULONG)wrote;
	lock_acquire();
	(void)dbg_ring_push(&g_ring, line, n);
	lock_release();
}

static NTSTATUS open_log(_Out_ HANDLE *file)
{
	UNICODE_STRING path;
	OBJECT_ATTRIBUTES oa;
	IO_STATUS_BLOCK io;

	RtlInitUnicodeString(&path, L"\\SystemRoot\\Temp\\qcwlan-dbg.log");
	InitializeObjectAttributes(&oa, &path,
				   OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL,
				   NULL);
	return ZwCreateFile(file, FILE_APPEND_DATA | SYNCHRONIZE, &oa, &io, NULL,
			    FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, FILE_OPEN_IF,
			    FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE |
				    FILE_WRITE_THROUGH,
			    NULL, 0);
}

static void write_all(_In_ HANDLE file, _In_ const void *buf, _In_ ULONG n)
{
	IO_STATUS_BLOCK io;
	LARGE_INTEGER off;

	off.QuadPart = -1;
	(void)ZwWriteFile(file, NULL, NULL, NULL, &io, (PVOID)buf, n, &off, NULL);
}

static VOID log_thread(_In_ PVOID context)
{
	HANDLE file = NULL;
	UCHAR chunk[4096];
	const char ready[] = "qcwlan-dbglog ready hook\n";
	UNREFERENCED_PARAMETER(context);

	for (;;) {
		unsigned n;
		LARGE_INTEGER interval;

		if (file == NULL && open_log(&file) == STATUS_SUCCESS)
			write_all(file, ready, sizeof(ready) - 1);
		if (file != NULL) {
			lock_acquire();
			n = dbg_ring_peek(&g_ring, chunk, sizeof(chunk));
			if (n)
				dbg_ring_consume(&g_ring, n);
			lock_release();
			if (n)
				write_all(file, chunk, n);
		}
		if (KeReadStateEvent(&g_stop))
			break;
		interval.QuadPart = -1000000; /* 100 ms */
		KeDelayExecutionThread(KernelMode, FALSE, &interval);
	}
	if (file != NULL)
		ZwClose(file);
	PsTerminateSystemThread(STATUS_SUCCESS);
}

#include "trace.h"

static VOID unload(_In_ PDRIVER_OBJECT driver)
{
	UNREFERENCED_PARAMETER(driver);
	trace_stop();
	if (g_callback)
		DbgSetDebugPrintCallback(debug_print_callback, FALSE);
	g_callback = FALSE;
	KeSetEvent(&g_stop, IO_NO_INCREMENT, FALSE);
	if (g_thread != NULL) {
		KeWaitForSingleObject(g_thread, Executive, KernelMode, FALSE, NULL);
		ObDereferenceObject(g_thread);
		g_thread = NULL;
	}
	if (g_storage != NULL) {
		ExFreePool(g_storage);
		g_storage = NULL;
	}
}

NTSTATUS DriverEntry(_In_ PDRIVER_OBJECT driver, _In_ PUNICODE_STRING registry)
{
	HANDLE thread;
	NTSTATUS status;

	UNREFERENCED_PARAMETER(registry);
	g_callback = FALSE;
	g_thread = NULL;
	g_storage = NULL;
	KeInitializeEvent(&g_stop, NotificationEvent, FALSE);
	driver->DriverUnload = unload;
	g_storage = ExAllocatePool2(POOL_FLAG_NON_PAGED, RING_CAP, 'gLDQ');
	if (g_storage == NULL)
		return STATUS_SUCCESS;
	g_ring.cap = RING_CAP;
	g_ring.w = 0;
	g_ring.r = 0;
	g_ring.b = g_storage;
	KeInitializeEvent(&g_stop, NotificationEvent, FALSE);
	status = DbgSetDebugPrintCallback(debug_print_callback, TRUE);
	if (NT_SUCCESS(status))
		g_callback = TRUE;
	status = PsCreateSystemThread(&thread, THREAD_ALL_ACCESS, NULL, NULL, NULL,
				      log_thread, NULL);
	if (!NT_SUCCESS(status))
		return STATUS_SUCCESS;
	status = ObReferenceObjectByHandle(thread, SYNCHRONIZE, *PsThreadType,
					   KernelMode, (PVOID *)&g_thread, NULL);
	ZwClose(thread);
	if (!NT_SUCCESS(status))
		g_thread = NULL;
	trace_start();
	return STATUS_SUCCESS;
}
