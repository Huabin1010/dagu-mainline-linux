#!/usr/bin/env python3
from fs import open_fs
from pyfatfs.PyFat import PyFat
from pathlib import Path

out = Path(__file__).resolve().parents[1] / "port/dagu/Silicon/Qualcomm/QcomPkg/Drivers/TestLabBridgeDxe/TestLabFatDisk.bin"
out.parent.mkdir(parents=True, exist_ok=True)
if out.exists():
    out.unlink()
pf = PyFat()
pf.mkfs(str(out), fat_type=PyFat.FAT_TYPE_FAT32, size=8 * 1024 * 1024, label="TESTLAB")
pf.open(str(out))
fs = open_fs(f"fat://{out}?writeable=1")
fs.makedirs("TESTLAB")
files = {
    "TESTLAB/BOOT.LOG": "",
    "TESTLAB/BOOT.SEQ": "0\n",
    "TESTLAB/COMMAND.IN": "",
    "TESTLAB/COMMAND.ACK": "OK\n",
    "TESTLAB/STATUS.JSON": '{"seq":0,"usb":"pending","bridge":"v2"}\n',
}
for name, content in files.items():
    fs.writetext(name, content)
fs.close()
pf.close()
print(f"OK {out.stat().st_size}")
