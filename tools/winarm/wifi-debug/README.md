# qcwlan debug capture kit

Copy `run.cmd` and `qcwlan-debug.reg` plus `dbgviewcli64a.exe` (Sysinternals DebugView, ARM64 CLI) into one folder,
e.g. `ESP:\dagu-wifi-debug`, then from an elevated prompt in Windows:

    mountvol S: /S
    S:\dagu-wifi-debug\run.cmd

It turns on the qcwlan driver debug output (`MPGlobalDebugLevel`, `MPGlobalDebugComponents`, `GlobalDebugLogOutput=1` -> DbgPrintEx) on class instance 0001, opens the
kernel Debug Print Filter, restarts the QCA6390 device and logs 120 s of kernel debug output to `qcwlan-dbg.log`.
The boot-time file is `C:\Windows\Temp\qcwlan-dbg.log`, written by `qcwlan-dbglog.sys`.
