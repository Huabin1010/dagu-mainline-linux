# Pinned single-thread dependent mul+add chain per core; compares core clocks (stage 13).
# Usage from the host: tools/winarm/dagu-ps.sh - < tools/winarm/core-bench.ps1
$src = @"
using System; using System.Diagnostics; using System.Runtime.InteropServices; using System.Threading;
public class CB {
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
  [DllImport("kernel32.dll")] static extern UIntPtr SetThreadAffinityMask(IntPtr h, UIntPtr m);
  public static double Run(int core) {
    double r = 0;
    Thread t = new Thread(() => {
      SetThreadAffinityMask(GetCurrentThread(), (UIntPtr)(1UL << core));
      Thread.Sleep(20);
      long x = 1; var sw = Stopwatch.StartNew();
      for (long i = 0; i < 200000000; i++) { x = x * 3 + i; }   // dependent mul+add chain
      sw.Stop(); r = 200.0 / sw.Elapsed.TotalSeconds + (x == 7 ? 1 : 0);   // M iters/s
    });
    t.Start(); t.Join(); return r;
  }
}
"@
Add-Type -TypeDefinition $src
"cores=" + [Environment]::ProcessorCount
foreach ($c in 0..([Environment]::ProcessorCount-1)) { "core $c : {0:N0} Miter/s" -f [CB]::Run($c) }
