/*
 * HexagonFS mapped file/directory operations
 *
 * Copyright (C) 2023 The Sensor Shell Contributors
 *
 * This file is part of sensh.
 *
 * Sensh is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include "hexagonfs.h"

#ifndef SYS_renameat
#include <sys/syscall.h>
#endif

static int dagu_renameat(int olddirfd, const char *oldpath,
			 int newdirfd, const char *newpath)
{
	return syscall(SYS_renameat, olddirfd, oldpath, newdirfd, newpath);
}

struct mapped_ctx {
	int fd;
	DIR *dir;
};

static void mapped_close(void *fd_data)
{
	struct mapped_ctx *ctx = fd_data;

	if (ctx->dir != NULL)
		closedir(ctx->dir);
	else
		close(ctx->fd);

	free(ctx);
}

static int mapped_from_dirent(const void *dirent_data, bool dir, void **fd_data)
{
	struct mapped_ctx *ctx;
	const char *name = dirent_data;
	int flags = O_RDONLY;
	int ret;

	ctx = malloc(sizeof(struct mapped_ctx));
	if (ctx == NULL)
		return -ENOMEM;

	if (dir)
		flags |= O_DIRECTORY;

	ctx->fd = open(name, flags);
	if (ctx->fd == -1) {
		ret = -errno;
		goto err;
	}

	ctx->dir = NULL;

	*fd_data = ctx;

	return 0;

err:
	free(ctx);
	return ret;
}

static int mapped_openat(struct hexagonfs_fd *dir,
			 const char *segment,
			 bool expect_dir,
			 int oflags,
			 struct hexagonfs_fd **out)
{
	struct mapped_ctx *dir_ctx = dir->data;
	struct hexagonfs_fd *fd;
	struct mapped_ctx *ctx;
	int flags = O_RDONLY;
	int ret;

	ctx = malloc(sizeof(struct mapped_ctx));
	if (ctx == NULL)
		return -ENOMEM;

	fd = malloc(sizeof(struct hexagonfs_fd));
	if (fd == NULL) {
		ret = -ENOMEM;
		goto err;
	}

	if (expect_dir)
		flags = O_RDONLY | O_DIRECTORY;
	else if (oflags)
		flags = oflags;

	ctx->fd = openat(dir_ctx->fd, segment, flags, 0644);
	if (ctx->fd == -1) {
		ret = -errno;
		goto err_free_fd;
	}

	ctx->dir = NULL;

	fd->is_assigned = false;
	fd->up = dir;
	fd->ops = &hexagonfs_mapped_ops;
	fd->data = ctx;

	*out = fd;

	return 0;

err_free_fd:
	free(fd);
err:
	free(ctx);
	return ret;
}

static int mapped_dup(struct hexagonfs_fd *src, struct hexagonfs_fd **out)
{
	struct mapped_ctx *src_ctx = src->data;
	struct mapped_ctx *ctx;
	struct hexagonfs_fd *fd;
	int ret;

	if (src_ctx == NULL)
		return -EBADF;

	ctx = malloc(sizeof(struct mapped_ctx));
	if (ctx == NULL)
		return -ENOMEM;

	fd = malloc(sizeof(struct hexagonfs_fd));
	if (fd == NULL) {
		free(ctx);
		return -ENOMEM;
	}

	ctx->fd = dup(src_ctx->fd);
	if (ctx->fd < 0) {
		ret = -errno;
		free(fd);
		free(ctx);
		return ret;
	}
	ctx->dir = NULL;

	fd->is_assigned = false;
	fd->up = src->up;
	fd->ops = src->ops;
	fd->data = ctx;
	*out = fd;

	return 0;
}

static ssize_t mapped_read(struct hexagonfs_fd *fd, size_t size, void *out)
{
	struct mapped_ctx *ctx = fd->data;
	ssize_t ret;

	ret = read(ctx->fd, out, size);
	if (ret < 0)
		return -errno;

	return ret;
}

static ssize_t mapped_write(struct hexagonfs_fd *fd, size_t size, const void *in)
{
	struct mapped_ctx *ctx = fd->data;
	ssize_t ret;

	ret = write(ctx->fd, in, size);
	if (ret < 0)
		return -errno;

	return ret;
}

static int mapped_unlinkat(struct hexagonfs_fd *dir, const char *name)
{
	struct mapped_ctx *ctx = dir->data;

	if (ctx == NULL)
		return -ENOENT;

	if (unlinkat(ctx->fd, name, 0) < 0)
		return -errno;

	return 0;
}

static int mapped_renameat(struct hexagonfs_fd *olddir, const char *oldname,
			   struct hexagonfs_fd *newdir, const char *newname)
{
	struct mapped_ctx *old_ctx = olddir->data;
	struct mapped_ctx *new_ctx = newdir->data;

	if (old_ctx == NULL || new_ctx == NULL)
		return -ENOENT;

	if (dagu_renameat(old_ctx->fd, oldname, new_ctx->fd, newname) < 0)
		return -errno;

	return 0;
}

static int mapped_readdir(struct hexagonfs_fd *fd, size_t size, char *out)
{
	struct mapped_ctx *ctx = fd->data;
	struct dirent *ent;

	if (ctx->dir == NULL) {
		ctx->dir = fdopendir(ctx->fd);
		if (ctx->dir == NULL)
			return -errno;

		ctx->fd = dirfd(ctx->dir);
		if (ctx->fd == -1)
			return -errno;
	}

	errno = 0;

	ent = readdir(ctx->dir);
	if (ent == NULL) {
		out[0] = '\0';
		return -errno;
	}

	strncpy(out, ent->d_name, size);
	out[size - 1] = '\0';

	return 0;
}

static int mapped_seek(struct hexagonfs_fd *fd, off_t off, int whence)
{
	struct mapped_ctx *ctx = fd->data;
	int ret;

	ret = lseek(ctx->fd, off, whence);
	if (ret == -1)
		return -errno;

	return 0;
}

static int mapped_stat(struct hexagonfs_fd *fd, struct stat *stats)
{
	struct mapped_ctx *ctx = fd->data;
	struct stat phys;
	int ret;

	ret = fstat(ctx->fd, &phys);
	if (ret)
		return -errno;

	stats->st_size = phys.st_size;

	stats->st_dev = 0;
	stats->st_rdev = 0;

	stats->st_ino = 0;
	stats->st_nlink = 0;

	if (phys.st_mode & S_IFDIR) {
		stats->st_mode = S_IFDIR
			       | S_IRUSR | S_IXUSR
			       | S_IRGRP | S_IXGRP
			       | S_IROTH | S_IXOTH;
	} else {
		stats->st_mode = S_IFREG | S_IRUSR | S_IRGRP | S_IROTH;
	}

	stats->st_atim.tv_sec = phys.st_atim.tv_sec;
	stats->st_atim.tv_nsec = phys.st_atim.tv_nsec;
	stats->st_ctim.tv_sec = phys.st_ctim.tv_sec;
	stats->st_ctim.tv_nsec = phys.st_ctim.tv_nsec;
	stats->st_mtim.tv_sec = phys.st_mtim.tv_sec;
	stats->st_mtim.tv_nsec = phys.st_mtim.tv_nsec;

	return 0;
}

static void mapped_or_empty_close(void *fd_data)
{
	if (fd_data)
		mapped_close(fd_data);
}

static int mapped_or_empty_from_dirent(const void *dirent_data, bool dir, void **fd_data)
{
	int ret;

	ret = mapped_from_dirent(dirent_data, dir, fd_data);
	if (ret)
		*fd_data = NULL;

	return 0;
}

static int mapped_or_empty_openat(struct hexagonfs_fd *dir,
				  const char *segment,
				  bool expect_dir,
				  int oflags,
				  struct hexagonfs_fd **out)
{
	if (dir->data)
		return mapped_openat(dir, segment, expect_dir, oflags, out);
	else
		return -ENOENT;
}

static int mapped_or_empty_dup(struct hexagonfs_fd *src, struct hexagonfs_fd **out)
{
	struct hexagonfs_fd *fd;

	if (src->data)
		return mapped_dup(src, out);

	fd = malloc(sizeof(struct hexagonfs_fd));
	if (fd == NULL)
		return -ENOMEM;

	fd->is_assigned = false;
	fd->up = src->up;
	fd->ops = src->ops;
	fd->data = NULL;
	*out = fd;
	return 0;
}

static ssize_t mapped_or_empty_read(struct hexagonfs_fd *fd,
				    size_t size, void *out)
{
	if (fd->data)
		return mapped_read(fd, size, out);

	return 0;
}

static int mapped_or_empty_readdir(struct hexagonfs_fd *fd,
				   size_t size, char *out)
{
	if (fd->data) {
		return mapped_readdir(fd, size, out);
	} else {
		out[0] = '\0';
		return 0;
	}
}

static int mapped_or_empty_seek(struct hexagonfs_fd *fd, off_t off, int whence)
{
	if (fd->data)
		return mapped_seek(fd, off, whence);
	else
		return 0;
}

static ssize_t mapped_or_empty_write(struct hexagonfs_fd *fd,
				     size_t size, const void *in)
{
	if (fd->data)
		return mapped_write(fd, size, in);

	return -EBADF;
}

static int mapped_or_empty_unlinkat(struct hexagonfs_fd *dir, const char *name)
{
	if (dir->data)
		return mapped_unlinkat(dir, name);

	return -ENOENT;
}

static int mapped_or_empty_stat(struct hexagonfs_fd *fd, struct stat *stats)
{
	if (fd->data) {
		return mapped_stat(fd, stats);
	} else {
		stats->st_size = 0;
		stats->st_dev = 0;
		stats->st_rdev = 0;
		stats->st_ino = 0;
		stats->st_nlink = 0;

		stats->st_mode = S_IFDIR
			       | S_IRUSR | S_IXUSR
			       | S_IRGRP | S_IXGRP
			       | S_IROTH | S_IXOTH;

		stats->st_atim.tv_sec = 0;
		stats->st_atim.tv_nsec = 0;
		stats->st_ctim.tv_sec = 0;
		stats->st_ctim.tv_nsec = 0;
		stats->st_mtim.tv_sec = 0;
		stats->st_mtim.tv_nsec = 0;

		return 0;
	}
}

/*
 * This is the sysfs variant of the stat function.
 *
 * The remote processor expects a non-zero size if the file is not empty, even
 * if a size cannot be determined without reading. The size is 256 on
 * downstream kernels, so set it to that.
 *
 * Otherwise, the existing stat() function can be used.
 */
static int mapped_sysfs_stat(struct hexagonfs_fd *fd, struct stat *stats)
{
	int ret;

	ret = mapped_stat(fd, stats);
	if (ret)
		return ret;

	if (!(stats->st_mode & S_IFDIR))
		stats->st_size = 256;

	return 0;
}

struct hexagonfs_file_ops hexagonfs_mapped_ops = {
	.close = mapped_close,
	.from_dirent = mapped_from_dirent,
	.openat = mapped_openat,
	.read = mapped_read,
	.write = mapped_write,
	.unlinkat = mapped_unlinkat,
	.renameat = mapped_renameat,
	.dup = mapped_dup,
	.readdir = mapped_readdir,
	.seek = mapped_seek,
	.stat = mapped_stat,
};

struct hexagonfs_file_ops hexagonfs_mapped_or_empty_ops = {
	.close = mapped_or_empty_close,
	.from_dirent = mapped_or_empty_from_dirent,
	.openat = mapped_or_empty_openat,
	.read = mapped_or_empty_read,
	.write = mapped_or_empty_write,
	.unlinkat = mapped_or_empty_unlinkat,
	.renameat = mapped_renameat,
	.dup = mapped_or_empty_dup,
	.readdir = mapped_or_empty_readdir,
	.seek = mapped_or_empty_seek,
	.stat = mapped_or_empty_stat,
};

struct hexagonfs_file_ops hexagonfs_mapped_sysfs_ops = {
	.close = mapped_close,
	.from_dirent = mapped_from_dirent,
	.openat = mapped_openat,
	.read = mapped_read,
	.write = mapped_write,
	.unlinkat = mapped_unlinkat,
	.renameat = mapped_renameat,
	.dup = mapped_dup,
	.readdir = mapped_readdir,
	.seek = mapped_seek,
	.stat = mapped_sysfs_stat,
};
