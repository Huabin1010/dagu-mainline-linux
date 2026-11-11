/* Host tests for the shim diagnostic record and path-ring layout.
 * Build and run:
 *   cc -O1 -Wall -Wextra -o /tmp/test_diag tests/test_diag.c && /tmp/test_diag
 * Diagnostic format only; not a root-cause fix.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "../dagu-shim-diag.h"

static int g_fail, g_run;
#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); g_fail++; } } while (0)
#define TEST(fn) do { printf("%s\n", #fn); g_run++; fn(); } while (0)

static void test_sizes(void)
{
    CHECK(sizeof(DIAG_REC) == DIAG_REC_V3_SIZE);
    CHECK(DIAG_REC_V2_SIZE == 76 * 4);
    CHECK((unsigned)__builtin_offsetof(DIAG_REC, PathCount) == DIAG_REC_V2_SIZE);
    CHECK((unsigned)__builtin_offsetof(DIAG_REC, Magic) == 0);
    CHECK((unsigned)__builtin_offsetof(DIAG_REC, Pad) == DIAG_REC_V2_SIZE - 4);
}

static void test_roundtrip(void)
{
    DIAG_REC r, o;
    unsigned char buf[DIAG_REC_V3_SIZE];
    memset(&r, 0, sizeof(r));
    r.Magic = DIAG_MAGIC;
    r.Ver = DIAG_VER;
    r.BootGen = 2;
    r.Step = 0x30;
    r.LogCount = 3;
    r.Hist[0] = 0x6e6;
    r.Lsite[0] = 0xaf084;
    r.PathCount = 4;
    r.PathInstall = 0xff;
    r.PathId[0] = PATH_ID_AC9C0;
    r.PathSite[0] = 0x301d4;
    r.PathFl[0] = PATH_FL_ENTER | PATH_FL_LEAVE;
    r.PathRet[0] = 0;
    r.PathId[1] = PATH_ID_D5D48;
    r.PathSite[1] = 0xacb3c;
    r.PathFl[1] = PATH_FL_ENTER | PATH_FL_LEAVE;
    r.PathRet[1] = 0; /* miss vs hit distinguished by PathRet */
    r.PathId[2] = PATH_ID_ADC00_DISP;
    r.PathSite[2] = 0xad30c;
    r.PathFl[2] = PATH_FL_ENTER | PATH_FL_LEAVE;
    r.PathRet[2] = 0;
    r.PathId[3] = PATH_ID_FREE_CA;
    r.PathSite[3] = 0x2ca8e0;
    r.PathFl[3] = PATH_FL_ENTER; /* no LEAVE: SError inside 0x2D0430 */
    memcpy(buf, &r, sizeof(r));
    memset(&o, 0, sizeof(o));
    memcpy(&o, buf, sizeof(o));
    CHECK(o.Magic == 0x47414444u);
    CHECK(o.Ver == 3);
    CHECK(o.Hist[0] == 0x6e6);
    CHECK(o.PathCount == 4);
    CHECK(o.PathInstall == 0xff);
    CHECK(o.PathId[3] == PATH_ID_FREE_CA);
    CHECK(o.PathFl[3] == PATH_FL_ENTER);
    CHECK((o.PathFl[0] & PATH_FL_LEAVE) != 0);
    /* v2 prefix readable at the front of a v3 blob */
    CHECK(*(const ULONG *)buf == DIAG_MAGIC);
}

/* Same enter/leave pairing the driver uses for nested wraps. */
static void path_enter(ULONG *cnt, ULONG *id, ULONG *site, ULONG *retv, ULONG *fl, ULONG sid, ULONG rva)
{
    ULONG idx = (*cnt) & 15;
    id[idx] = sid; site[idx] = rva; retv[idx] = 0; fl[idx] = PATH_FL_ENTER;
    (*cnt)++;
}
static void path_leave(ULONG *cnt, ULONG *id, ULONG *retv, ULONG *fl, ULONG sid, ULONG rv)
{
    ULONG n = *cnt, i;
    for (i = 0; i < 16 && i < n; i++) {
        ULONG idx = (n - 1 - i) & 15;
        if (id[idx] == sid && (fl[idx] & PATH_FL_ENTER) && !(fl[idx] & PATH_FL_LEAVE)) {
            retv[idx] = rv;
            fl[idx] |= PATH_FL_LEAVE;
            return;
        }
    }
}

static void test_nested_path(void)
{
    ULONG cnt = 0, id[16], site[16], retv[16], fl[16];
    memset(id, 0, sizeof(id)); memset(site, 0, sizeof(site));
    memset(retv, 0, sizeof(retv)); memset(fl, 0, sizeof(fl));
    path_enter(&cnt, id, site, retv, fl, PATH_ID_AC9C0, 0x301d4);
    path_enter(&cnt, id, site, retv, fl, PATH_ID_D5D48, 0xacb3c);
    path_leave(&cnt, id, retv, fl, PATH_ID_D5D48, 0xc0000001);
    path_enter(&cnt, id, site, retv, fl, PATH_ID_ADC00_DISP, 0xad30c);
    path_leave(&cnt, id, retv, fl, PATH_ID_ADC00_DISP, 0);
    /* AC9C0 did not leave: crash still inside display init */
    CHECK(cnt == 3);
    CHECK(id[0] == PATH_ID_AC9C0 && fl[0] == PATH_FL_ENTER);
    CHECK(id[1] == PATH_ID_D5D48 && fl[1] == (PATH_FL_ENTER|PATH_FL_LEAVE));
    CHECK(retv[1] == 0xc0000001);
    CHECK(id[2] == PATH_ID_ADC00_DISP && (fl[2] & PATH_FL_LEAVE));
}

int main(void)
{
    TEST(test_sizes);
    TEST(test_roundtrip);
    TEST(test_nested_path);
    printf("%d tests, %d failed\n", g_run, g_fail);
    return g_fail ? 1 : 0;
}
