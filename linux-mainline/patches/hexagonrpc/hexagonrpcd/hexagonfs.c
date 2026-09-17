/*
 * Virtual read-only filesystem for Hexagon processors
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

#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include "hexagonfs.h"

static char *copy_segment_and_advance(const char *path,
				      bool *trailing_slash,
				      const char **next)
{
	const char *next_tmp;
	char *segment;
	size_t segment_len;

	next_tmp = strchr(path, '/');
	if (next_tmp == NULL) {
		next_tmp = &path[strlen(path)];
		*trailing_slash = false;
	} else {
		*trailing_slash = true;
	}

	segment_len = next_tmp - path;

	while (*next_tmp == '/')
		next_tmp++;

	segment = malloc(segment_len + 1);
	if (segment == NULL)
		return NULL;

	memcpy(segment, path, segment_len);
	segment[segment_len] = 0;

	*next = next_tmp;

	return segment;
}

static struct hexagonfs_fd *pop_dir(struct hexagonfs_fd *dir,
				    struct hexagonfs_fd *root)
{
	struct hexagonfs_fd *up;

	if (dir != root && dir->up != NULL) {
		up = dir->up;

		if (!dir->is_assigned) {
			dir->ops->close(dir->data);
			free(dir);
		}
	} else {
		up = dir;
	}

	return up;
}

static int allocate_file_number(struct hexagonfs_fd **fds,
				struct hexagonfs_fd *fd)
{
	size_t i;

	for (i = 0; i < HEXAGONFS_MAX_FD; i++) {
		if (fds[i] == NULL) {
			fd->is_assigned = true;
			fds[i] = fd;
			return (int)i;
		}
	}

	return -EMFILE;
}

static bool hexagonfs_is_live(struct hexagonfs_fd **fds, struct hexagonfs_fd *node)
{
	size_t i;
	struct hexagonfs_fd *p;

	if (node == NULL)
		return false;
	if (node->is_assigned)
		return true;
	for (i = 0; i < HEXAGONFS_MAX_FD; i++) {
		for (p = fds[i]; p != NULL; p = p->up) {
			if (p == node)
				return true;
		}
	}
	return false;
}

static void destroy_unowned(struct hexagonfs_fd **fds, struct hexagonfs_fd *fd)
{
	struct hexagonfs_fd *curr = fd;
	struct hexagonfs_fd *next;

	while (curr != NULL && !curr->is_assigned && !hexagonfs_is_live(fds, curr)) {
		next = curr->up;
		curr->ops->close(curr->data);
		free(curr);
		curr = next;
	}
}

int hexagonfs_open_root(struct hexagonfs_fd **fds, struct hexagonfs_dirent *root)
{
	struct hexagonfs_fd *fd;
	int ret;

	fd = malloc(sizeof(struct hexagonfs_fd));
	if (fd == NULL)
		return -ENOMEM;

	fd->is_assigned = false;
	fd->up = NULL;
	fd->ops = root->ops;

	ret = root->ops->from_dirent(root->u.ptr, true, &fd->data);
	if (ret)
		goto err;

	ret = allocate_file_number(fds, fd);
	if (ret < 0)
		goto err;

	return ret;

err:
	destroy_unowned(fds, fd);
	return ret;
}

int hexagonfs_openat(struct hexagonfs_fd **fds, int rootfd, int dirfd,
		     const char *name, int oflags)
{
	struct hexagonfs_fd *fd;
	const char *curr = name;
	char *segment;
	bool expect_dir;
	int selected = dirfd;
	int ret = 0;
	int seg_flags;

	if (*curr == '/') {
		selected = rootfd;

		while (*curr == '/')
			curr++;
	}

	fd = fds[selected];

	while (*curr != '\0' && !ret) {
		segment = copy_segment_and_advance(curr, &expect_dir, &curr);
		if (segment == NULL) {
			ret = -ENOMEM;
			goto err;
		}

		if (!strcmp(segment, ".")) {
			goto next;
		} else if (!strcmp(segment, "..")) {
			fd = pop_dir(fd, fds[rootfd]);
		} else {
			seg_flags = (*curr == '\0' && !expect_dir) ? oflags : 0;
			ret = fd->ops->openat(fd, segment, expect_dir,
					      seg_flags, &fd);
		}

	next:
		free(segment);
	}

	if (ret)
		goto err;

	/*
	 * `..` / open_parent can land on a live dir (opendir or a file's
	 * unassigned parent). Assigning that object a second slot then
	 * fclose()s the live dir (EBADF after persist rename).
	 */
	if (fd->is_assigned || hexagonfs_is_live(fds, fd)) {
		if (fd->ops->dup == NULL) {
			ret = -EBUSY;
			goto err;
		}
		ret = fd->ops->dup(fd, &fd);
		if (ret)
			goto err;
		fprintf(stderr, "hexagonfs: dup before second assign\n");
	}

	ret = allocate_file_number(fds, fd);
	if (ret < 0)
		goto err;

	return ret;

err:
	destroy_unowned(fds, fd);

	return ret;
}

int hexagonfs_close(struct hexagonfs_fd **fds, int fileno)
{
	struct hexagonfs_fd *fd;

	if (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
		return -EBADF;

	fd = fds[fileno];
	if (fd == NULL || fd->ops == NULL)
		return -EBADF;

	fds[fileno] = NULL;
	fd->is_assigned = false;
	destroy_unowned(fds, fd);

	return 0;
}

int hexagonfs_lseek(struct hexagonfs_fd **fds, int fileno, off_t off, int whence)
{
	struct hexagonfs_fd *fd;

	if (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
		return -EBADF;

	fd = fds[fileno];
	if (fd == NULL)
		return -EBADF;

	if (fd->ops->seek == NULL)
		return -ENOSYS;

	return fd->ops->seek(fd, off, whence);
}

ssize_t hexagonfs_read(struct hexagonfs_fd **fds, int fileno, size_t size, void *ptr)
{
	struct hexagonfs_fd *fd;

	if (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
		return -EBADF;

	fd = fds[fileno];
	if (fd == NULL)
		return -EBADF;

	if (fd->ops->read == NULL)
		return -ENOSYS;

	return fd->ops->read(fd, size, ptr);
}

ssize_t hexagonfs_write(struct hexagonfs_fd **fds, int fileno, size_t size, const void *ptr)
{
	struct hexagonfs_fd *fd;

	if (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
		return -EBADF;

	fd = fds[fileno];
	if (fd == NULL)
		return -EBADF;

	if (fd->ops->write == NULL)
		return -ENOSYS;

	return fd->ops->write(fd, size, ptr);
}

int hexagonfs_unlink(struct hexagonfs_fd **fds, int rootfd, const char *name)
{
	char *dup;
	char *slash;
	const char *base;
	const char *parent;
	int dirfd;
	int ret;
	int close_dir = 0;

	if (name == NULL || name[0] == '\0')
		return -EINVAL;

	dup = strdup(name);
	if (dup == NULL)
		return -ENOMEM;

	slash = strrchr(dup, '/');
	if (slash != NULL && slash[1] == '\0') {
		while (slash > dup && *slash == '/') {
			*slash = '\0';
			slash--;
		}
		slash = strrchr(dup, '/');
	}

	if (slash != NULL) {
		base = slash + 1;
		if (slash == dup) {
			parent = "/";
		} else {
			*slash = '\0';
			parent = dup;
		}
		dirfd = hexagonfs_openat(fds, rootfd, rootfd, parent, 0);
		close_dir = 1;
	} else {
		base = dup;
		dirfd = rootfd;
	}

	if (dirfd < 0) {
		ret = dirfd;
		goto out;
	}

	if (fds[dirfd] == NULL || fds[dirfd]->ops->unlinkat == NULL) {
		ret = -EPERM;
		goto close;
	}

	ret = fds[dirfd]->ops->unlinkat(fds[dirfd], base);

close:
	if (close_dir)
		hexagonfs_close(fds, dirfd);
out:
	free(dup);
	return ret;
}

static int hexagonfs_open_parent(struct hexagonfs_fd **fds, int rootfd,
				 const char *name, char **dup_out,
				 const char **base_out, int *close_dir)
{
	char *dup;
	char *slash;
	const char *parent;
	int dirfd;

	*close_dir = 0;
	*dup_out = NULL;
	*base_out = NULL;

	if (name == NULL || name[0] == '\0')
		return -EINVAL;

	dup = strdup(name);
	if (dup == NULL)
		return -ENOMEM;

	slash = strrchr(dup, '/');
	if (slash != NULL && slash[1] == '\0') {
		while (slash > dup && *slash == '/') {
			*slash = '\0';
			slash--;
		}
		slash = strrchr(dup, '/');
	}

	if (slash != NULL) {
		*base_out = slash + 1;
		if (slash == dup)
			parent = "/";
		else {
			*slash = '\0';
			parent = dup;
		}
		dirfd = hexagonfs_openat(fds, rootfd, rootfd, parent, 0);
		*close_dir = 1;
	} else {
		*base_out = dup;
		dirfd = rootfd;
	}

	*dup_out = dup;
	return dirfd;
}

int hexagonfs_rename(struct hexagonfs_fd **fds, int rootfd,
		     const char *oldname, const char *newname)
{
	char *old_dup = NULL, *new_dup = NULL;
	const char *old_base, *new_base;
	int old_dir = -1, new_dir = -1;
	int close_old = 0, close_new = 0;
	int ret;

	old_dir = hexagonfs_open_parent(fds, rootfd, oldname, &old_dup,
					&old_base, &close_old);
	if (old_dir < 0) {
		ret = old_dir;
		goto out;
	}

	new_dir = hexagonfs_open_parent(fds, rootfd, newname, &new_dup,
					&new_base, &close_new);
	if (new_dir < 0) {
		ret = new_dir;
		goto out;
	}

	if (fds[old_dir] == NULL || fds[new_dir] == NULL
	 || fds[old_dir]->ops->renameat == NULL
	 || fds[old_dir]->ops != fds[new_dir]->ops) {
		ret = -EXDEV;
		goto out;
	}

	ret = fds[old_dir]->ops->renameat(fds[old_dir], old_base,
					  fds[new_dir], new_base);

out:
	if (close_new)
		hexagonfs_close(fds, new_dir);
	if (close_old && old_dir != new_dir)
		hexagonfs_close(fds, old_dir);
	free(old_dup);
	free(new_dup);
	return ret;
}

int hexagonfs_readdir(struct hexagonfs_fd **fds, int fileno, size_t ent_size, char *ent)
{
	struct hexagonfs_fd *fd;

	if (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
		return -EBADF;

	fd = fds[fileno];
	if (fd == NULL)
		return -EBADF;

	if (fd->ops->readdir == NULL)
		return -ENOSYS;

	return fd->ops->readdir(fd, ent_size, ent);
}

int hexagonfs_fstat(struct hexagonfs_fd **fds, int fileno, struct stat *stats)
{
	struct hexagonfs_fd *fd;

	if (fileno < 0 || fileno >= HEXAGONFS_MAX_FD)
		return -EBADF;

	fd = fds[fileno];
	if (fd == NULL)
		return -EBADF;

	if (fd->ops->stat == NULL)
		return -ENOSYS;

	return fd->ops->stat(fd, stats);
}
