{ ... }:
{
  # ── Memory pressure: zram, swap tuning, and per-app caps.
  #
  # Diagnosis (Aug 2026): the desktop stuttered when launching Zen or VS Code,
  # and gamemode barely helped. It wasn't CPU — /proc/pressure/cpu sat at 0.00
  # under load and quickshell used ~1.2% CPU. The real signal was I/O stall
  # (root io.pressure full avg300=4.17, i.e. ~12s of every 5min with *every*
  # task blocked) driven by swap thrash: 3.3 GB written to swap in 86 minutes,
  # with 101 MB of quickshell and 57 MB of Hyprland itself paged out.
  #
  # That last part is the whole symptom. Launching a heavy app is an allocation
  # burst, which forces reclaim, which evicts compositor pages; touching the bar
  # afterwards faults them back off NVMe. Hence "lag when opening the browser".

  # Compressed RAM swap. Anonymous pages compress ~3:1 under zstd, so a 50%
  # device holds roughly 7.5 GB of pages in ~2.5 GB of real RAM — and a page
  # fault costs microseconds instead of an NVMe round trip.
  #
  # The 8.8 GB swap partition in hardware-configuration.nix is deliberately
  # kept as a second tier. zramSwap.priority defaults to 5; swap devices with
  # no explicit priority get negative ones from the kernel, so zram always
  # fills first and the partition only catches overflow.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  boot.kernel.sysctl = {
    # Raised from the default 60, which is counterintuitive but correct here:
    # with zram, swapping an anon page is cheaper than dropping page cache, so
    # the kernel should prefer it. This value only makes sense *because* zram
    # is enabled above — drop it back to 60 if zram is ever removed.
    "vm.swappiness" = 100;

    # Default 3 reads 2^3 = 8 pages per swap-in to amortise disk seek cost.
    # zram has no seek cost, so that readahead is pure wasted decompression.
    # 0 means fault in exactly the page that was asked for.
    "vm.page-cluster" = 0;
  };

  # The other half of this — the per-app memory ceiling on Zen, the largest
  # single consumer — lives in ../home/app-limits.nix. It has to be a *user*
  # unit drop-in, and environment.etc cannot place one: NixOS already owns
  # /etc/systemd/user as a generated store symlink, so writing beneath it
  # fails the etc build outright with a permission error.
}
