#!/usr/bin/env python3
"""Keep fastrpc_user alive until in-flight DSP contexts finish.

Close races fastrpc_context_put_wq: device_release kfree(fl) while
fastrpc_buf_free still loads fl->cctx (offset 0x5e8). That Oopsed
CPU0 during systemd reboot and left the board half-down.

DMA free uses the alloc cookie stored at buf->phys, not the SID-tagged
IOVA. Each invoke context holds a kref on fastrpc_user until context_free.
"""
from __future__ import annotations

import sys
from pathlib import Path

root = Path(sys.argv[1])
path = root / "drivers/misc/fastrpc.c"
text = path.read_text()
marker = "dagu: FastRPC user kref lives past close"
if marker in text:
    print(f"{path}: already patched")
    sys.exit(0)


def must_replace(hay: str, old: str, new: str, what: str) -> str:
    if old not in hay:
        raise SystemExit(f"{path}: needle missing for {what}")
    return hay.replace(old, new, 1)


text = must_replace(
    text,
    """\tstruct device *dev;
\tvoid *virt;
\tdma_addr_t dma_addr;
\tu64 size;
""",
    """\tstruct device *dev;
\tvoid *virt;
\tdma_addr_t dma_addr;
\tdma_addr_t phys; /* dagu: dma_alloc_coherent cookie; dma_addr may include SID */
\tu64 size;
""",
    "fastrpc_buf.phys",
)

text = must_replace(
    text,
    """\t/* lock for allocations */
\tstruct mutex mutex;
};
""",
    """\t/* lock for allocations */
\tstruct mutex mutex;
\tstruct kref refcount; /* dagu: FastRPC user kref lives past close */
};
""",
    "fastrpc_user.refcount",
)

text = must_replace(
    text,
    """static void fastrpc_buf_free(struct fastrpc_buf *buf)
{
	dma_free_coherent(buf->dev, buf->size, buf->virt,
			  fastrpc_ipa_to_dma_addr(buf->fl->cctx, buf->dma_addr));
	kfree(buf);
}
""",
    """static void fastrpc_buf_free(struct fastrpc_buf *buf)
{
	/* dagu: FastRPC DMA cookie — free with alloc handle, not SID-tagged IOVA */
	dma_free_coherent(buf->dev, buf->size, buf->virt, buf->phys);
	kfree(buf);
}
""",
    "fastrpc_buf_free",
)

text = must_replace(
    text,
    """\tbuf->virt = dma_alloc_coherent(dev, buf->size, &buf->dma_addr,
				       GFP_KERNEL);
	if (!buf->virt) {
		mutex_destroy(&buf->lock);
		kfree(buf);
		return -ENOMEM;
	}

	*obuf = buf;
""",
    """\tbuf->virt = dma_alloc_coherent(dev, buf->size, &buf->dma_addr,
				       GFP_KERNEL);
	if (!buf->virt) {
		mutex_destroy(&buf->lock);
		kfree(buf);
		return -ENOMEM;
	}
	buf->phys = buf->dma_addr;

	*obuf = buf;
""",
    "buf->phys = dma cookie",
)

text = must_replace(
    text,
    """static void fastrpc_channel_ctx_put(struct fastrpc_channel_ctx *cctx)
{
	kref_put(&cctx->refcount, fastrpc_channel_ctx_free);
}

static void fastrpc_context_free(struct kref *ref)
{
	struct fastrpc_invoke_ctx *ctx;
	struct fastrpc_channel_ctx *cctx;
	unsigned long flags;
	int i;

	ctx = container_of(ref, struct fastrpc_invoke_ctx, refcount);
	cctx = ctx->cctx;

	for (i = 0; i < ctx->nbufs; i++)
		fastrpc_map_put(ctx->maps[i]);

	if (ctx->buf)
		fastrpc_buf_free(ctx->buf);

	spin_lock_irqsave(&cctx->lock, flags);
	idr_remove(&cctx->ctx_idr, ctx->ctxid >> 4);
	spin_unlock_irqrestore(&cctx->lock, flags);

	kfree(ctx->maps);
	kfree(ctx->olaps);
	kfree(ctx);

	fastrpc_channel_ctx_put(cctx);
}
""",
    """static void fastrpc_channel_ctx_put(struct fastrpc_channel_ctx *cctx)
{
	kref_put(&cctx->refcount, fastrpc_channel_ctx_free);
}

static void fastrpc_session_free(struct fastrpc_channel_ctx *cctx,
				 struct fastrpc_session_ctx *session);

static void fastrpc_user_free(struct kref *ref)
{
	struct fastrpc_user *fl = container_of(ref, struct fastrpc_user, refcount);
	struct fastrpc_channel_ctx *cctx = fl->cctx;
	struct fastrpc_map *map, *m;
	struct fastrpc_buf *buf, *b;

	if (fl->init_mem)
		fastrpc_buf_free(fl->init_mem);

	list_for_each_entry_safe(map, m, &fl->maps, node)
		fastrpc_map_put(map);

	list_for_each_entry_safe(buf, b, &fl->mmaps, node) {
		list_del(&buf->node);
		fastrpc_buf_free(buf);
	}

	if (fl->sctx)
		fastrpc_session_free(cctx, fl->sctx);

	fastrpc_channel_ctx_put(cctx);
	mutex_destroy(&fl->mutex);
	kfree(fl);
}

static void fastrpc_user_get(struct fastrpc_user *fl)
{
	kref_get(&fl->refcount);
}

static void fastrpc_user_put(struct fastrpc_user *fl)
{
	kref_put(&fl->refcount, fastrpc_user_free);
}

static void fastrpc_context_free(struct kref *ref)
{
	struct fastrpc_invoke_ctx *ctx;
	struct fastrpc_channel_ctx *cctx;
	struct fastrpc_user *fl;
	unsigned long flags;
	int i;

	ctx = container_of(ref, struct fastrpc_invoke_ctx, refcount);
	cctx = ctx->cctx;
	fl = ctx->fl;

	spin_lock(&fl->lock);
	if (!list_empty(&ctx->node))
		list_del_init(&ctx->node);
	spin_unlock(&fl->lock);

	for (i = 0; i < ctx->nbufs; i++)
		fastrpc_map_put(ctx->maps[i]);

	if (ctx->buf)
		fastrpc_buf_free(ctx->buf);

	spin_lock_irqsave(&cctx->lock, flags);
	idr_remove(&cctx->ctx_idr, ctx->ctxid >> 4);
	spin_unlock_irqrestore(&cctx->lock, flags);

	kfree(ctx->maps);
	kfree(ctx->olaps);
	kfree(ctx);

	fastrpc_user_put(fl);
	fastrpc_channel_ctx_put(cctx);
}
""",
    "user kref + context_free",
)

text = must_replace(
    text,
    """	/* Released in fastrpc_context_put() */
	fastrpc_channel_ctx_get(cctx);

	ctx->sc = sc;
""",
    """	/* Released in fastrpc_context_put() */
	fastrpc_channel_ctx_get(cctx);
	/* Released in fastrpc_context_free() */
	fastrpc_user_get(user);

	ctx->sc = sc;
""",
    "context_alloc user_get",
)

text = must_replace(
    text,
    """err_idr:
	spin_lock(&user->lock);
	list_del(&ctx->node);
	spin_unlock(&user->lock);
	fastrpc_channel_ctx_put(cctx);
""",
    """err_idr:
	spin_lock(&user->lock);
	list_del_init(&ctx->node);
	spin_unlock(&user->lock);
	fastrpc_user_put(user);
	fastrpc_channel_ctx_put(cctx);
""",
    "context_alloc err_idr user_put",
)

text = must_replace(
    text,
    """	ret = dma_get_sgtable(buffer->dev, &a->sgt, buffer->virt,
			      fastrpc_ipa_to_dma_addr(buffer->fl->cctx, buffer->dma_addr),
			      buffer->size);
""",
    """	ret = dma_get_sgtable(buffer->dev, &a->sgt, buffer->virt,
			      buffer->phys,
			      buffer->size);
""",
    "dma_get_sgtable phys",
)

text = must_replace(
    text,
    """	return dma_mmap_coherent(buf->dev, vma, buf->virt,
				 fastrpc_ipa_to_dma_addr(buf->fl->cctx, buf->dma_addr), size);
""",
    """	return dma_mmap_coherent(buf->dev, vma, buf->virt, buf->phys, size);
""",
    "dma_mmap_coherent phys",
)

text = must_replace(
    text,
    """		spin_lock(&fl->lock);
		list_del(&ctx->node);
		spin_unlock(&fl->lock);
		fastrpc_context_put(ctx);
""",
    """		spin_lock(&fl->lock);
		list_del_init(&ctx->node);
		spin_unlock(&fl->lock);
		fastrpc_context_put(ctx);
""",
    "invoke list_del_init",
)

text = must_replace(
    text,
    """static void fastrpc_session_free(struct fastrpc_channel_ctx *cctx,
				 struct fastrpc_session_ctx *session)
{
	unsigned long flags;

	spin_lock_irqsave(&cctx->lock, flags);
	session->used = false;
	spin_unlock_irqrestore(&cctx->lock, flags);
}

static int fastrpc_release_current_dsp_process(struct fastrpc_user *fl)
""",
    """static void fastrpc_session_free(struct fastrpc_channel_ctx *cctx,
				 struct fastrpc_session_ctx *session)
{
	unsigned long flags;

	spin_lock_irqsave(&cctx->lock, flags);
	session->used = false;
	spin_unlock_irqrestore(&cctx->lock, flags);
}

static int fastrpc_release_current_dsp_process(struct fastrpc_user *fl)
""",
    "session_free identity",
)

text = must_replace(
    text,
    """static int fastrpc_device_release(struct inode *inode, struct file *file)
{
	struct fastrpc_user *fl = (struct fastrpc_user *)file->private_data;
	struct fastrpc_channel_ctx *cctx = fl->cctx;
	struct fastrpc_invoke_ctx *ctx, *n;
	struct fastrpc_map *map, *m;
	struct fastrpc_buf *buf, *b;
	unsigned long flags;

	fastrpc_release_current_dsp_process(fl);

	spin_lock_irqsave(&cctx->lock, flags);
	list_del(&fl->user);
	spin_unlock_irqrestore(&cctx->lock, flags);

	if (fl->init_mem)
		fastrpc_buf_free(fl->init_mem);

	list_for_each_entry_safe(ctx, n, &fl->pending, node) {
		list_del(&ctx->node);
		fastrpc_context_put(ctx);
	}

	list_for_each_entry_safe(map, m, &fl->maps, node)
		fastrpc_map_put(map);

	list_for_each_entry_safe(buf, b, &fl->mmaps, node) {
		list_del(&buf->node);
		fastrpc_buf_free(buf);
	}

	fastrpc_session_free(cctx, fl->sctx);
	fastrpc_channel_ctx_put(cctx);

	mutex_destroy(&fl->mutex);
	kfree(fl);
	file->private_data = NULL;

	return 0;
}
""",
    """static int fastrpc_device_release(struct inode *inode, struct file *file)
{
	struct fastrpc_user *fl = (struct fastrpc_user *)file->private_data;
	struct fastrpc_channel_ctx *cctx = fl->cctx;
	struct fastrpc_invoke_ctx *ctx, *n;
	unsigned long flags;
	LIST_HEAD(to_put);

	fastrpc_release_current_dsp_process(fl);

	spin_lock_irqsave(&cctx->lock, flags);
	list_del(&fl->user);
	spin_unlock_irqrestore(&cctx->lock, flags);

	spin_lock(&fl->lock);
	list_replace_init(&fl->pending, &to_put);
	spin_unlock(&fl->lock);

	list_for_each_entry_safe(ctx, n, &to_put, node) {
		list_del_init(&ctx->node);
		ctx->retval = -EPIPE;
		complete(&ctx->work);
		fastrpc_context_put(ctx);
	}

	file->private_data = NULL;
	fastrpc_user_put(fl);

	return 0;
}
""",
    "device_release user_put",
)

text = must_replace(
    text,
    """	/* Released in fastrpc_device_release() */
	fastrpc_channel_ctx_get(cctx);

	filp->private_data = fl;
	spin_lock_init(&fl->lock);
	mutex_init(&fl->mutex);
	INIT_LIST_HEAD(&fl->pending);
	INIT_LIST_HEAD(&fl->maps);
	INIT_LIST_HEAD(&fl->mmaps);
	INIT_LIST_HEAD(&fl->user);
	fl->cctx = cctx;
	fl->is_secure_dev = fdevice->secure;

	fl->sctx = fastrpc_session_alloc(fl);
	if (!fl->sctx) {
		dev_err(&cctx->rpdev->dev, "No session available\\n");
		mutex_destroy(&fl->mutex);
		kfree(fl);

		return -EBUSY;
	}
""",
    """	/* Released in fastrpc_user_free() */
	fastrpc_channel_ctx_get(cctx);

	filp->private_data = fl;
	spin_lock_init(&fl->lock);
	mutex_init(&fl->mutex);
	kref_init(&fl->refcount);
	INIT_LIST_HEAD(&fl->pending);
	INIT_LIST_HEAD(&fl->maps);
	INIT_LIST_HEAD(&fl->mmaps);
	INIT_LIST_HEAD(&fl->user);
	fl->cctx = cctx;
	fl->is_secure_dev = fdevice->secure;

	fl->sctx = fastrpc_session_alloc(fl);
	if (!fl->sctx) {
		dev_err(&cctx->rpdev->dev, "No session available\\n");
		fastrpc_user_put(fl);

		return -EBUSY;
	}
""",
    "device_open kref_init",
)

path.write_text(text)
print(f"patched {path}: {marker}")
