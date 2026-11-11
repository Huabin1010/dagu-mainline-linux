/* SPDX-License-Identifier: MIT
 * Shared diagnostic record for dagu-smmushim.
 * This is a measurement format only. A new record is not a root-cause fix.
 *
 * v1/v2 prefix is unchanged through Fmdschi/Pad so an old parser can still
 * read the leading fields of a v3 record. v3 appends the path-hook ring.
 */
#ifndef DAGU_SHIM_DIAG_H
#define DAGU_SHIM_DIAG_H

#ifdef _KERNEL_MODE
#else
#include <stdint.h>
typedef uint32_t ULONG;
#endif

#define DIAG_MAGIC 0x47414444u /* 'DDAG' */
#define DIAG_VER   3u
#define DIAG_VER_V2 2u
#define DIAG_PATH_CAP 16u
#define DIAG_PATH_NSITE 8u

/* Path hook ids. Stable numbers for dump/shim.bin parsers. */
#define PATH_ID_AC9C0      1u  /* wrap bl 0x301D4 -> 0xAC9C0 */
#define PATH_ID_ADC00_DISP 2u  /* wrap bl 0xAD30C -> 0xADC00 */
#define PATH_ID_ADC00_OTH  3u  /* wrap bl 0x355FC -> 0xADC00 */
#define PATH_ID_D5D48      4u  /* wrap bl 0xACB3C -> 0xD5D48 */
#define PATH_ID_FREE_CA    5u  /* wrap bl 0x2CA8E0 -> 0x2D0430 */
#define PATH_ID_FREE_CE    6u  /* wrap bl 0x2CEB8C -> 0x2D0430 */
#define PATH_ID_FREE_D0    7u  /* wrap bl 0x2D0148 -> 0x2D0430 */
#define PATH_ID_FREE_D3    8u  /* wrap bl 0x2D03A0 -> 0x2D0430 */

#define PATH_FL_ENTER 1u
#define PATH_FL_LEAVE 2u

typedef struct _DIAG_REC {
    ULONG Magic, Ver, BootGen, Step, Fail, Fsite, Ncall, Nfail, Rst;
    ULONG Fminst, Fmseen, Fmlast, Fmcall, Fmhit, Fmaflt, Fmbflt;
    ULONG LogCount;
    ULONG Hist[16], Lsite[16];
    ULONG OvIns, OvLen, OvFlt;
    ULONG AcpN, AcpF, AcpK[4], AcpL[4];
    ULONG Adlo, Adhi, A630, A638lo, A638hi, A780, A46c4, Aflt;
    ULONG QPatch, QPendStep, Ihit, Fmdsclo, Fmdschi, Pad;
    /* v3: path-hook ring. PathCount is the total number of enters.
     * PathInstall bit i is 1 if kPathSite[i] was patched. */
    ULONG PathCount, PathInstall;
    ULONG PathId[16], PathSite[16], PathRet[16], PathFl[16];
} DIAG_REC;

#define DIAG_REC_V2_SIZE 304u
#define DIAG_REC_V3_SIZE 568u

#endif /* DAGU_SHIM_DIAG_H */
