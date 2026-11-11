/* SPDX-License-Identifier: MIT
 * dagu-iommu.h: the IOVA allocator and AArch64 stage-1 page table behind
 * the dagu SMMU shim (stage 25).
 *
 * qcdx asks its SMMU interface for address spaces (slot 6, one per ENGS
 * PAGETABLES entry), IOVAs inside them (slots 24/25 -> 20) and for an MDL to
 * be mapped at an IOVA (slot 14). This file is that engine with no Windows
 * dependency, so the host unit tests (tests/test_iommu.c) exercise exactly
 * the code the driver runs. Memory comes from caller-supplied callbacks.
 *
 * Page table format is what Linux io-pgtable-arm builds for the Adreno CB0
 * and what stage 24 proved Windows may program: 4 KB granule, 39-bit input
 * per TTBR half (T0SZ = T1SZ = 25, TCR2.SEP = bit 39), three levels
 * (L1 bits 38:30, L2 29:21, L3 20:12), 4 KB leaf pages only.
 */
#ifndef DAGU_IOMMU_H
#define DAGU_IOMMU_H

typedef unsigned long long iu64;
typedef unsigned int iu32;

#define IOMMU_PAGE        0x1000ull
#define IOMMU_VA_BITS     39u
#define IOMMU_VA_MASK     ((1ull << IOMMU_VA_BITS) - 1)
#define IOMMU_ENTRIES     512u

/* Stage-1 descriptor bits (io-pgtable-arm.c). */
#define PTE_VALID         (1ull << 0)
#define PTE_TABLE         (3ull << 0)
#define PTE_PAGE          (3ull << 0)
#define PTE_ATTRIDX(i)    ((iu64)(i) << 2)
#define PTE_AP_UNPRIV     (1ull << 6)
#define PTE_AP_RDONLY     (1ull << 7)
#define PTE_SH_OS         (2ull << 8)
#define PTE_SH_IS         (3ull << 8)
#define PTE_AF            (1ull << 10)
#define PTE_NG            (1ull << 11)
#define PTE_XN            (3ull << 53)
#define PTE_ADDR_MASK     0x0000FFFFFFFFF000ull

/* MAIR0 = 0xF404FF44 (Linux): idx0 Normal-NC, idx1 WB-RWA, idx2 Device,
 * idx3 inner-NC/outer-WB. */
#define IOMMU_ATTR_NC     0u
#define IOMMU_ATTR_CACHED 1u
#define IOMMU_ATTR_DEVICE 2u

#define IOMMU_PROT_READ   0x1u
#define IOMMU_PROT_WRITE  0x2u
#define IOMMU_PROT_CACHE  0x4u
#define IOMMU_PROT_MMIO   0x8u

#define IOMMU_OK          0
#define IOMMU_ENOMEM      (-1)
#define IOMMU_EINVAL      (-2)
#define IOMMU_EBUSY       (-3)
#define IOMMU_ENOSPC      (-4)

typedef struct {
    /* One zeroed 4 KB page the SMMU can walk: returns its CPU pointer and
     * sets *pa. NULL on failure. */
    void *(*table_alloc)(void *ctx, iu64 *pa);
    void (*table_free)(void *ctx, void *va, iu64 pa);
    /* Ordinary zeroed memory for bookkeeping the SMMU never reads. */
    void *(*meta_alloc)(void *ctx, iu64 bytes);
    void (*meta_free)(void *ctx, void *p);
    void *ctx;
} IOMMU_OPS;

/* ---- page table ---------------------------------------------------------- */

/* Each hardware table has a shadow of child CPU pointers, so the walk never
 * has to turn a physical address back into a virtual one. */
typedef struct IOMMU_NODE {
    iu64 *tbl;
    iu64 pa;
    struct IOMMU_NODE *child[IOMMU_ENTRIES];
    iu32 used;                      /* valid entries in tbl */
} IOMMU_NODE;

typedef struct {
    const IOMMU_OPS *ops;
    IOMMU_NODE *root;               /* level 1 */
    iu32 tables;                    /* hardware pages in use */
    iu64 mapped;                    /* bytes currently mapped */
} IOMMU_PT;

static IOMMU_NODE *
iommu_node_new(IOMMU_PT *pt)
{
    IOMMU_NODE *n = (IOMMU_NODE *)pt->ops->meta_alloc(pt->ops->ctx, sizeof(IOMMU_NODE));
    iu32 i;

    if (!n)
        return 0;
    n->tbl = (iu64 *)pt->ops->table_alloc(pt->ops->ctx, &n->pa);
    if (!n->tbl || (n->pa & (IOMMU_PAGE - 1))) {
        if (n->tbl)
            pt->ops->table_free(pt->ops->ctx, n->tbl, n->pa);
        pt->ops->meta_free(pt->ops->ctx, n);
        return 0;
    }
    for (i = 0; i < IOMMU_ENTRIES; i++) {
        n->tbl[i] = 0;
        n->child[i] = 0;
    }
    n->used = 0;
    pt->tables++;
    return n;
}

static void
iommu_node_free(IOMMU_PT *pt, IOMMU_NODE *n, iu32 level)
{
    iu32 i;

    if (!n)
        return;
    if (level < 3)
        for (i = 0; i < IOMMU_ENTRIES; i++)
            iommu_node_free(pt, n->child[i], level + 1);
    pt->ops->table_free(pt->ops->ctx, n->tbl, n->pa);
    pt->ops->meta_free(pt->ops->ctx, n);
    pt->tables--;
}

static int
iommu_pt_init(IOMMU_PT *pt, const IOMMU_OPS *ops)
{
    pt->ops = ops;
    pt->tables = 0;
    pt->mapped = 0;
    pt->root = iommu_node_new(pt);
    return pt->root ? IOMMU_OK : IOMMU_ENOMEM;
}

static void
iommu_pt_destroy(IOMMU_PT *pt)
{
    iommu_node_free(pt, pt->root, 1);
    pt->root = 0;
    pt->mapped = 0;
}

static iu64
iommu_pt_root(const IOMMU_PT *pt)
{
    return pt->root ? pt->root->pa : 0;
}

static iu32
iommu_idx(iu64 va, iu32 level)
{
    return (iu32)((va >> (12u + 9u * (3u - level))) & (IOMMU_ENTRIES - 1));
}

static iu64
iommu_pte(iu64 pa, iu32 prot)
{
    iu64 pte = (pa & PTE_ADDR_MASK) | PTE_PAGE | PTE_AF | PTE_NG | PTE_AP_UNPRIV;

    if (!(prot & IOMMU_PROT_WRITE))
        pte |= PTE_AP_RDONLY;
    if (prot & IOMMU_PROT_MMIO)
        pte |= PTE_ATTRIDX(IOMMU_ATTR_DEVICE) | PTE_SH_OS;
    else if (prot & IOMMU_PROT_CACHE)
        pte |= PTE_ATTRIDX(IOMMU_ATTR_CACHED) | PTE_SH_IS;
    else
        pte |= PTE_ATTRIDX(IOMMU_ATTR_NC) | PTE_SH_OS;
    return pte;
}

/* Leaf slot for va, creating the L2/L3 tables on the way when make != 0. */
static iu64 *
iommu_walk(IOMMU_PT *pt, iu64 va, int make, IOMMU_NODE **leaf)
{
    IOMMU_NODE *n = pt->root;
    iu32 level;

    for (level = 1; level < 3; level++) {
        iu32 i = iommu_idx(va, level);
        IOMMU_NODE *c = n->child[i];

        if (!c) {
            if (!make)
                return 0;
            c = iommu_node_new(pt);
            if (!c)
                return 0;
            n->child[i] = c;
            n->used++;
            /* Table contents must be visible before the walker can see
             * the descriptor pointing at them. */
            __sync_synchronize();
            n->tbl[i] = c->pa | PTE_TABLE;
        }
        n = c;
    }
    *leaf = n;
    return &n->tbl[iommu_idx(va, 3)];
}

/* Unmap [va, va+size). Returns bytes that were mapped. Empty L3 tables are
 * kept: freeing them would need a TLB walk-cache flush before reuse, and the
 * table count is bounded by the VA actually used. */
static iu64
iommu_unmap(IOMMU_PT *pt, iu64 va, iu64 size)
{
    iu64 done = 0, off;

    if (!pt->root || (va & (IOMMU_PAGE - 1)) || (size & (IOMMU_PAGE - 1)))
        return 0;
    for (off = 0; off < size; off += IOMMU_PAGE) {
        IOMMU_NODE *leaf;
        iu64 *slot = iommu_walk(pt, (va + off) & IOMMU_VA_MASK, 0, &leaf);

        if (slot && (*slot & PTE_VALID)) {
            *slot = 0;
            leaf->used--;
            done += IOMMU_PAGE;
        }
    }
    pt->mapped -= done;
    __sync_synchronize();
    return done;
}

/* Map npages pages whose frame numbers are pfn[0..npages) at va. All or
 * nothing: on failure every page this call mapped is unmapped again. */
static int
iommu_map_pfns(IOMMU_PT *pt, iu64 va, const iu64 *pfn, iu64 npages, iu32 prot)
{
    iu64 i;

    if (!pt->root || (va & (IOMMU_PAGE - 1)) || !npages)
        return IOMMU_EINVAL;
    if (((va & IOMMU_VA_MASK) + npages * IOMMU_PAGE - 1) > IOMMU_VA_MASK)
        return IOMMU_EINVAL;
    for (i = 0; i < npages; i++) {
        IOMMU_NODE *leaf;
        iu64 *slot = iommu_walk(pt, (va + i * IOMMU_PAGE) & IOMMU_VA_MASK, 1, &leaf);
        int rc;

        if (!slot)
            rc = IOMMU_ENOMEM;
        else if (*slot & PTE_VALID)
            rc = IOMMU_EBUSY;
        else if ((pfn[i] << 12) & ~PTE_ADDR_MASK)
            rc = IOMMU_EINVAL;
        else {
            *slot = iommu_pte(pfn[i] << 12, prot);
            leaf->used++;
            pt->mapped += IOMMU_PAGE;
            continue;
        }
        if (i)
            iommu_unmap(pt, va, i * IOMMU_PAGE);
        return rc;
    }
    __sync_synchronize();
    return IOMMU_OK;
}

/* Leaf descriptor for va, 0 if unmapped. */
static iu64
iommu_lookup(IOMMU_PT *pt, iu64 va)
{
    IOMMU_NODE *leaf;
    iu64 *slot;

    if (!pt->root)
        return 0;
    slot = iommu_walk(pt, va & IOMMU_VA_MASK, 0, &leaf);
    return slot ? *slot : 0;
}

/* ---- IOVA allocator ------------------------------------------------------ */

typedef struct {
    iu64 start;
    iu64 end;                       /* exclusive */
} IOMMU_EXTENT;

typedef struct {
    const IOMMU_OPS *ops;
    iu64 base;
    iu64 size;
    IOMMU_EXTENT *ext;              /* sorted, non-overlapping, in use */
    iu32 count;
    iu32 cap;
} IOMMU_VA;

static int
iommu_va_init(IOMMU_VA *a, const IOMMU_OPS *ops, iu64 base, iu64 size, iu32 cap)
{
    if (!size || base + size < base || !cap)
        return IOMMU_EINVAL;
    a->ops = ops;
    a->base = base;
    a->size = size;
    a->count = 0;
    a->cap = cap;
    a->ext = (IOMMU_EXTENT *)ops->meta_alloc(ops->ctx, (iu64)cap * sizeof(IOMMU_EXTENT));
    return a->ext ? IOMMU_OK : IOMMU_ENOMEM;
}

static void
iommu_va_destroy(IOMMU_VA *a)
{
    if (a->ext)
        a->ops->meta_free(a->ops->ctx, a->ext);
    a->ext = 0;
    a->count = 0;
}

static void
iommu_va_insert(IOMMU_VA *a, iu32 at, iu64 start, iu64 end)
{
    iu32 j;

    for (j = a->count; j > at; j--)
        a->ext[j] = a->ext[j - 1];
    a->ext[at].start = start;
    a->ext[at].end = end;
    a->count++;
}

static iu64
iommu_align_up(iu64 v, iu64 align)
{
    return (v + align - 1) & ~(align - 1);
}

/* Bytes to request from a physically contiguous allocator so the block
 * starts on an align boundary. Windows only promises page alignment, so
 * the request is the smallest power of two >= max(size, align), passed
 * as both length and BoundaryAddressMultiple: a block that may not cross
 * a span boundary and is span bytes long must start on one. size must be
 * page-aligned and non-zero, align a power of two. Returns 0 when the span
 * would exceed max_span. */
static iu64
iommu_contig_span(iu64 size, iu64 align, iu64 max_span)
{
    iu64 need, span;

    if (!size || (size & (IOMMU_PAGE - 1)) || !align || (align & (align - 1)))
        return 0;
    if (align <= IOMMU_PAGE)
        return size;
    need = size > align ? size : align;
    span = align;
    while (span < need) {
        if (span > (max_span >> 1))
            return 0;
        span <<= 1;
    }
    return span <= max_span ? span : 0;
}

/* First fit of size bytes, aligned, inside [lo, hi) and the allocator's
 * window. align must be a power of two >= 4 KB. Returns 0 on failure;
 * callers keep IOVA 0 out of every window, so 0 is never a real result. */
static iu64
iommu_va_alloc(IOMMU_VA *a, iu64 size, iu64 align, iu64 lo, iu64 hi)
{
    iu64 cur, end;
    iu32 i;

    if (!size || (size & (IOMMU_PAGE - 1)) || align < IOMMU_PAGE || (align & (align - 1)))
        return 0;
    if (a->count >= a->cap)
        return 0;
    if (lo < a->base)
        lo = a->base;
    if (lo < IOMMU_PAGE)
        lo = IOMMU_PAGE;                /* 0 is the failure value */
    end = a->base + a->size;
    if (hi > end || hi == 0)
        hi = end;
    cur = iommu_align_up(lo, align);
    for (i = 0; i <= a->count; i++) {
        iu64 gap_end = (i < a->count) ? a->ext[i].start : end;

        if (i < a->count && a->ext[i].end <= cur)
            continue;
        if (gap_end > hi)
            gap_end = hi;
        if (cur >= lo && cur + size >= cur && cur + size <= gap_end) {
            iommu_va_insert(a, i, cur, cur + size);
            return cur;
        }
        if (i < a->count)
            cur = iommu_align_up(a->ext[i].end, align);
        if (cur >= hi || cur < lo)
            return 0;
    }
    return 0;
}

/* Claim exactly [va, va+size). */
static int
iommu_va_reserve(IOMMU_VA *a, iu64 va, iu64 size)
{
    iu32 i;

    if (!size || (va & (IOMMU_PAGE - 1)) || (size & (IOMMU_PAGE - 1)) || va + size < va)
        return IOMMU_EINVAL;
    if (va < a->base || va + size > a->base + a->size)
        return IOMMU_EINVAL;
    if (a->count >= a->cap)
        return IOMMU_ENOSPC;
    for (i = 0; i < a->count; i++) {
        if (a->ext[i].end <= va)
            continue;
        if (a->ext[i].start < va + size)
            return IOMMU_EBUSY;
        break;
    }
    iommu_va_insert(a, i, va, va + size);
    return IOMMU_OK;
}

/* Release the extent that starts at va. Returns its size, 0 if none. */
static iu64
iommu_va_free(IOMMU_VA *a, iu64 va)
{
    iu32 i, j;

    for (i = 0; i < a->count; i++) {
        if (a->ext[i].start == va) {
            iu64 sz = a->ext[i].end - a->ext[i].start;

            for (j = i; j + 1 < a->count; j++)
                a->ext[j] = a->ext[j + 1];
            a->count--;
            return sz;
        }
    }
    return 0;
}

/* ---- CB0 register values for the qcdx address layout --------------------- */

/* ENGS: GraphicsPerProcessPT lives below bit 39 (TTBR0), GraphicsGlobalPT
 * from 0x80_0000_0000 (TTBR1). Same fields Linux uses (stage 23), 39-bit
 * halves, both walks enabled unless a half has no table. */
#define IOMMU_TCR_HALF    (25u | (1u << 8) | (1u << 10) | (3u << 12))   /* T0SZ, WBWA, IS */
#define IOMMU_TCR_EPD0    (1u << 7)
#define IOMMU_TCR_EPD1    (1u << 23)
#define IOMMU_TCR_TG1_4K  (2u << 30)
/* PASIZE 36 bit, SEP = bit 39 (0b010), AS. */
#define IOMMU_TCR2_QCDX   (1u | (2u << 15) | (1u << 4))

static iu32
iommu_cb_tcr(int have_ttbr0, int have_ttbr1)
{
    iu32 tcr = IOMMU_TCR_HALF | ((IOMMU_TCR_HALF << 16) | IOMMU_TCR_TG1_4K);

    if (!have_ttbr0)
        tcr |= IOMMU_TCR_EPD0;
    if (!have_ttbr1)
        tcr |= IOMMU_TCR_EPD1;
    return tcr;
}

#endif /* DAGU_IOMMU_H */
