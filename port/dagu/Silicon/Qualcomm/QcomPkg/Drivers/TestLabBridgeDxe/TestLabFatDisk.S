# @file
#  Link the prebuilt TestLab FAT32 disk image into the driver.
#

    .section    .rodata, "a", %progbits
    .align      4
    .globl      TestLabFatDisk
    .globl      TestLabFatDiskEnd
TestLabFatDisk:
    .incbin     "TestLabFatDisk.bin"
TestLabFatDiskEnd:

    .globl      TestLabFatDiskSize
TestLabFatDiskSize:
    .long       TestLabFatDiskEnd - TestLabFatDisk
