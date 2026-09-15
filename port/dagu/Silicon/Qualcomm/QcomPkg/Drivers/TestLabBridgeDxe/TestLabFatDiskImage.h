/** @file
  External TestLab FAT32 disk image symbols.
**/

#ifndef TESTLAB_FAT_DISK_IMAGE_H_
#define TESTLAB_FAT_DISK_IMAGE_H_

extern CONST UINT8 TestLabFatDisk[];
extern CONST UINT8 TestLabFatDiskEnd[];
extern CONST UINT32 TestLabFatDiskSize;

#define TESTLAB_FAT_DISK_SIZE  (TestLabFatDiskEnd - TestLabFatDisk)

#endif
