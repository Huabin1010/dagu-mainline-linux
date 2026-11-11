/* Host unit tests for dagu-iommu.h (the shim's IOVA allocator and AArch64
 * stage-1 page table). Build and run:
 *   cc -O1 -Wall -Wextra -o /tmp/test_iommu tests/test_iommu.c && /tmp/test_iommu
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../dagu-iommu.h"

static int g_fail, g_run;
#define CHECK(c) do { if (!(c)) { printf("  FAIL %s:%d %s\n", __FILE__, __LINE__, #c); g_fail++; } } while (0)
#define TEST(fn) do { printf("%s\n", #fn); g_run++; fn(); } while (0)

/* Fake physical memory: table pages get PAs from a counter, so tests can
 * check the descriptor chain without real hardware. */
typedef struct {
    int tables_live, meta_live;
    int fail_table_after;           /* -1 = never */
    int fail_meta_after;
    iu64 next_pa;
} FAKE;

static void *f_table_alloc(void *ctx, iu64 *pa)
{
    FAKE *f = ctx;
    void *p;
    if (f->fail_table_after == 0)
        return NULL;
    if (f->fail_table_after > 0)
        f->fail_table_after--;
    p = aligned_alloc(4096, 4096);
    memset(p, 0xA5, 4096);          /* the engine must zero it */
    *pa = f->next_pa;
    f->next_pa += 0x1000;
    f->tables_live++;
    return p;
}
static void f_table_free(void *ctx, void *va, iu64 pa) { (void)pa; ((FAKE *)ctx)->tables_live--; free(va); }
static void *f_meta_alloc(void *ctx, iu64 n)
{
    FAKE *f = ctx;
    if (f->fail_meta_after == 0)
        return NULL;
    if (f->fail_meta_after > 0)
        f->fail_meta_after--;
    f->meta_live++;
    return calloc(1, n);
}
static void f_meta_free(void *ctx, void *p) { ((FAKE *)ctx)->meta_live--; free(p); }

static FAKE g_fake;
static IOMMU_OPS g_ops = { f_table_alloc, f_table_free, f_meta_alloc, f_meta_free, &g_fake };

static void reset(void)
{
    memset(&g_fake, 0, sizeof(g_fake));
    g_fake.fail_table_after = -1;
    g_fake.fail_meta_after = -1;
    g_fake.next_pa = 0x80000000ull;
}

/* ---- page table ---- */

static void test_init_gives_zeroed_root(void)
{
    IOMMU_PT pt; int i, nz = 0;
    reset();
    CHECK(iommu_pt_init(&pt, &g_ops) == IOMMU_OK);
    for (i = 0; i < 512; i++) nz += pt.root->tbl[i] != 0;
    CHECK(nz == 0);
    CHECK(iommu_pt_root(&pt) == 0x80000000ull);
    CHECK(pt.tables == 1);
    iommu_pt_destroy(&pt);
    CHECK(g_fake.tables_live == 0 && g_fake.meta_live == 0);
}

static void test_map_builds_three_level_chain(void)
{
    IOMMU_PT pt; iu64 pfn = 0x9C000, l1, l2, l3;
    reset();
    iommu_pt_init(&pt, &g_ops);
    /* VA 0x40201000: L1 idx 1, L2 idx 1, L3 idx 1 */
    CHECK(iommu_map_pfns(&pt, 0x40201000ull, &pfn, 1, IOMMU_PROT_READ | IOMMU_PROT_WRITE | IOMMU_PROT_CACHE) == IOMMU_OK);
    l1 = pt.root->tbl[1];
    CHECK((l1 & 3) == 3);
    l2 = pt.root->child[1]->tbl[1];
    CHECK((l2 & 3) == 3);
    CHECK((l1 & PTE_ADDR_MASK) == pt.root->child[1]->pa);
    CHECK((l2 & PTE_ADDR_MASK) == pt.root->child[1]->child[1]->pa);
    l3 = pt.root->child[1]->child[1]->tbl[1];
    CHECK((l3 & PTE_ADDR_MASK) == 0x9C000000ull);
    CHECK(pt.tables == 3);
    CHECK(pt.mapped == 0x1000);
    iommu_pt_destroy(&pt);
    CHECK(g_fake.tables_live == 0);
}

static void test_pte_attributes_follow_prot(void)
{
    iu64 rw = iommu_pte(0x1000, IOMMU_PROT_READ | IOMMU_PROT_WRITE | IOMMU_PROT_CACHE);
    iu64 ro = iommu_pte(0x1000, IOMMU_PROT_READ);
    iu64 io = iommu_pte(0x1000, IOMMU_PROT_READ | IOMMU_PROT_WRITE | IOMMU_PROT_MMIO);
    CHECK((rw & PTE_AP_RDONLY) == 0);
    CHECK((rw & (7ull << 2)) == PTE_ATTRIDX(IOMMU_ATTR_CACHED));
    CHECK((rw & (3ull << 8)) == PTE_SH_IS);
    CHECK(rw & PTE_AF);
    CHECK(rw & PTE_NG);
    CHECK(ro & PTE_AP_RDONLY);
    CHECK((ro & (7ull << 2)) == PTE_ATTRIDX(IOMMU_ATTR_NC));
    CHECK((io & (7ull << 2)) == PTE_ATTRIDX(IOMMU_ATTR_DEVICE));
}

static void test_ttbr1_va_uses_low_39_bits(void)
{
    IOMMU_PT pt; iu64 pfn = 0x123;
    reset();
    iommu_pt_init(&pt, &g_ops);
    /* GraphicsGlobalPT base 0x80_0000_0000 indexes as 0 inside TTBR1 */
    CHECK(iommu_map_pfns(&pt, 0x8000001000ull, &pfn, 1, IOMMU_PROT_READ) == IOMMU_OK);
    CHECK((pt.root->child[0]->child[0]->tbl[1] & PTE_ADDR_MASK) == 0x123000ull);
    CHECK((iommu_lookup(&pt, 0x8000001000ull) & PTE_ADDR_MASK) == 0x123000ull);
    iommu_pt_destroy(&pt);
}

static void test_map_rejects_overlap_and_rolls_back(void)
{
    IOMMU_PT pt; iu64 pfn[3] = { 1, 2, 3 }, one = 9;
    reset();
    iommu_pt_init(&pt, &g_ops);
    CHECK(iommu_map_pfns(&pt, 0x3000, &one, 1, IOMMU_PROT_READ) == IOMMU_OK);
    /* 0x1000..0x3fff overlaps the page at 0x3000 */
    CHECK(iommu_map_pfns(&pt, 0x1000, pfn, 3, IOMMU_PROT_READ) == IOMMU_EBUSY);
    CHECK(iommu_lookup(&pt, 0x1000) == 0);
    CHECK(iommu_lookup(&pt, 0x2000) == 0);
    CHECK((iommu_lookup(&pt, 0x3000) & PTE_ADDR_MASK) == 0x9000);
    CHECK(pt.mapped == 0x1000);
    iommu_pt_destroy(&pt);
}

static void test_map_rolls_back_when_table_alloc_fails(void)
{
    IOMMU_PT pt; iu64 pfn[2] = { 5, 6 };
    reset();
    iommu_pt_init(&pt, &g_ops);
    /* First page fits in the existing chain once built; force the second
     * page into a new L2 region and fail its table allocation. */
    CHECK(iommu_map_pfns(&pt, 0x3FFFF000ull, &pfn[0], 1, IOMMU_PROT_READ) == IOMMU_OK);
    iommu_unmap(&pt, 0x3FFFF000ull, 0x1000);
    g_fake.fail_table_after = 0;
    CHECK(iommu_map_pfns(&pt, 0x3FFFF000ull, pfn, 2, IOMMU_PROT_READ) == IOMMU_ENOMEM);
    CHECK(iommu_lookup(&pt, 0x3FFFF000ull) == 0);
    CHECK(pt.mapped == 0);
    g_fake.fail_table_after = -1;
    iommu_pt_destroy(&pt);
    CHECK(g_fake.tables_live == 0 && g_fake.meta_live == 0);
}

static void test_map_validates_arguments(void)
{
    IOMMU_PT pt; iu64 pfn = 1, big = 1ull << 40;
    reset();
    iommu_pt_init(&pt, &g_ops);
    CHECK(iommu_map_pfns(&pt, 0x1001, &pfn, 1, IOMMU_PROT_READ) == IOMMU_EINVAL);
    CHECK(iommu_map_pfns(&pt, 0x1000, &pfn, 0, IOMMU_PROT_READ) == IOMMU_EINVAL);
    CHECK(iommu_map_pfns(&pt, IOMMU_VA_MASK & ~0xFFFull, &pfn, 2, IOMMU_PROT_READ) == IOMMU_EINVAL);
    CHECK(iommu_map_pfns(&pt, 0x1000, &big, 1, IOMMU_PROT_READ) == IOMMU_EINVAL);
    CHECK(pt.mapped == 0);
    iommu_pt_destroy(&pt);
}

static void test_unmap_returns_only_mapped_bytes(void)
{
    IOMMU_PT pt; iu64 pfn[2] = { 7, 8 };
    reset();
    iommu_pt_init(&pt, &g_ops);
    iommu_map_pfns(&pt, 0x10000, pfn, 2, IOMMU_PROT_READ);
    CHECK(iommu_unmap(&pt, 0x0F000, 0x4000) == 0x2000);
    CHECK(iommu_unmap(&pt, 0x10000, 0x2000) == 0);
    CHECK(iommu_unmap(&pt, 0x10001, 0x1000) == 0);
    CHECK(pt.mapped == 0);
    /* page can be mapped again after unmap */
    CHECK(iommu_map_pfns(&pt, 0x10000, pfn, 1, IOMMU_PROT_READ) == IOMMU_OK);
    iommu_pt_destroy(&pt);
}

static void test_sparse_maps_share_tables(void)
{
    IOMMU_PT pt; iu64 pfn[512]; int i;
    reset();
    for (i = 0; i < 512; i++) pfn[i] = 0x1000 + i;
    iommu_pt_init(&pt, &g_ops);
    CHECK(iommu_map_pfns(&pt, 0x200000, pfn, 512, IOMMU_PROT_READ) == IOMMU_OK);   /* one full L3 */
    CHECK(pt.tables == 3);
    CHECK(iommu_map_pfns(&pt, 0x400000, pfn, 1, IOMMU_PROT_READ) == IOMMU_OK);     /* new L3, same L2 */
    CHECK(pt.tables == 4);
    CHECK(iommu_map_pfns(&pt, 0x7F00000000ull, pfn, 1, IOMMU_PROT_READ) == IOMMU_OK); /* new L2 + L3 */
    CHECK(pt.tables == 6);
    iommu_pt_destroy(&pt);
    CHECK(g_fake.tables_live == 0 && g_fake.meta_live == 0);
}

/* ---- IOVA allocator ---- */

static void test_alloc_first_fit_and_alignment(void)
{
    IOMMU_VA a;
    reset();
    CHECK(iommu_va_init(&a, &g_ops, 0x400000, 0x10000000, 8) == IOMMU_OK);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0, 0) == 0x400000);
    CHECK(iommu_va_alloc(&a, 0x2000, 0x100000, 0, 0) == 0x500000);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0, 0) == 0x401000);   /* fills the gap */
    CHECK(a.count == 3);
    iommu_va_destroy(&a);
    CHECK(g_fake.meta_live == 0);
}

static void test_alloc_never_returns_zero(void)
{
    IOMMU_VA a;
    reset();
    iommu_va_init(&a, &g_ops, 0, 0x80000000ull, 4);   /* GraphicsGmuPT starts at 0 */
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0, 0) == 0x1000);
    iommu_va_destroy(&a);
}

static void test_free_and_reuse(void)
{
    IOMMU_VA a; iu64 x, y;
    reset();
    iommu_va_init(&a, &g_ops, 0x100000, 0x100000, 8);
    x = iommu_va_alloc(&a, 0x10000, 0x1000, 0, 0);
    y = iommu_va_alloc(&a, 0x10000, 0x1000, 0, 0);
    CHECK(iommu_va_free(&a, x) == 0x10000);
    CHECK(iommu_va_free(&a, x) == 0);                  /* double free is a no-op */
    CHECK(iommu_va_alloc(&a, 0x8000, 0x1000, 0, 0) == x);
    CHECK(iommu_va_free(&a, y + 0x1000) == 0);         /* not a start */
    iommu_va_destroy(&a);
}

static void test_exhaustion_and_capacity(void)
{
    IOMMU_VA a;
    reset();
    iommu_va_init(&a, &g_ops, 0x1000, 0x3000, 2);
    CHECK(iommu_va_alloc(&a, 0x4000, 0x1000, 0, 0) == 0);  /* bigger than window */
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0, 0) == 0x1000);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0, 0) == 0x2000);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0, 0) == 0);  /* extent table full */
    iommu_va_destroy(&a);
}

static void test_alloc_rejects_bad_requests(void)
{
    IOMMU_VA a;
    reset();
    iommu_va_init(&a, &g_ops, 0x1000, 0x100000, 4);
    CHECK(iommu_va_alloc(&a, 0, 0x1000, 0, 0) == 0);
    CHECK(iommu_va_alloc(&a, 0x800, 0x1000, 0, 0) == 0);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x3000, 0, 0) == 0);  /* not a power of two */
    CHECK(iommu_va_alloc(&a, 0x1000, 0x800, 0, 0) == 0);
    iommu_va_destroy(&a);
}

static void test_alloc_honours_lo_hi(void)
{
    IOMMU_VA a;
    reset();
    iommu_va_init(&a, &g_ops, 0x1000, 0x100000, 4);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0x50000, 0x52000) == 0x50000);
    CHECK(iommu_va_alloc(&a, 0x2000, 0x1000, 0x50000, 0x52000) == 0);
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0x50000, 0x52000) == 0x51000);
    iommu_va_destroy(&a);
}

static void test_reserve_exact_and_conflicts(void)
{
    IOMMU_VA a;
    reset();
    iommu_va_init(&a, &g_ops, 0, 0x100000000ull, 8);
    CHECK(iommu_va_reserve(&a, 0x9C000000ull, 0xFA0000) == IOMMU_OK);
    CHECK(iommu_va_reserve(&a, 0x9CF00000ull, 0x1000) == IOMMU_EBUSY);
    CHECK(iommu_va_reserve(&a, 0x9C001000ull, 0x1000) == IOMMU_EBUSY);
    CHECK(iommu_va_reserve(&a, 0x9CFA0000ull, 0x1000) == IOMMU_OK);   /* adjacent is fine */
    CHECK(iommu_va_reserve(&a, 0xFFFFF000ull, 0x2000) == IOMMU_EINVAL);
    CHECK(iommu_va_reserve(&a, 0x1001, 0x1000) == IOMMU_EINVAL);
    /* dynamic allocation skips the reserved block */
    CHECK(iommu_va_alloc(&a, 0x1000, 0x1000, 0x9C000000ull, 0) == 0x9CFA1000ull);
    iommu_va_destroy(&a);
}

static void test_init_rejects_bad_window(void)
{
    IOMMU_VA a;
    reset();
    CHECK(iommu_va_init(&a, &g_ops, 0x1000, 0, 4) == IOMMU_EINVAL);
    CHECK(iommu_va_init(&a, &g_ops, ~0ull - 0xFFF, 0x2000, 4) == IOMMU_EINVAL);
    g_fake.fail_meta_after = 0;
    CHECK(iommu_va_init(&a, &g_ops, 0x1000, 0x1000, 4) == IOMMU_ENOMEM);
}

/* ---- CB0 register values ---- */

static void test_tcr_matches_linux_fields_for_qcdx_split(void)
{
    iu32 both = iommu_cb_tcr(1, 1), hi = iommu_cb_tcr(0, 1);
    CHECK((both & 0x3F) == 25);                       /* T0SZ */
    CHECK(((both >> 16) & 0x3F) == 25);               /* T1SZ */
    CHECK(((both >> 30) & 3) == 2);                   /* TG1 = 4 KB */
    CHECK(((both >> 14) & 3) == 0);                   /* TG0 = 4 KB */
    CHECK((both & (IOMMU_TCR_EPD0 | IOMMU_TCR_EPD1)) == 0);
    CHECK(hi & IOMMU_TCR_EPD0);
    /* upper half equals Linux 0xb5100080 except T1SZ (25 vs 16) */
    CHECK((hi & 0xFFC00000u) == (0xB5100080u & 0xFFC00000u));
    CHECK(both == 0xB5193519u);
}

static void test_tcr2_sep_is_bit39(void)
{
    CHECK(((IOMMU_TCR2_QCDX >> 15) & 7) == 2);
    CHECK((IOMMU_TCR2_QCDX & 0xF) == 1);
    CHECK(IOMMU_TCR2_QCDX & (1u << 4));
}

int main(void)
{
    TEST(test_init_gives_zeroed_root);
    TEST(test_map_builds_three_level_chain);
    TEST(test_pte_attributes_follow_prot);
    TEST(test_ttbr1_va_uses_low_39_bits);
    TEST(test_map_rejects_overlap_and_rolls_back);
    TEST(test_map_rolls_back_when_table_alloc_fails);
    TEST(test_map_validates_arguments);
    TEST(test_unmap_returns_only_mapped_bytes);
    TEST(test_sparse_maps_share_tables);
    TEST(test_alloc_first_fit_and_alignment);
    TEST(test_alloc_never_returns_zero);
    TEST(test_free_and_reuse);
    TEST(test_exhaustion_and_capacity);
    TEST(test_alloc_rejects_bad_requests);
    TEST(test_alloc_honours_lo_hi);
    TEST(test_reserve_exact_and_conflicts);
    TEST(test_init_rejects_bad_window);
    TEST(test_tcr_matches_linux_fields_for_qcdx_split);
    TEST(test_tcr2_sep_is_bit39);
    printf("%d tests, %d failures\n", g_run, g_fail);
    return g_fail != 0;
}
