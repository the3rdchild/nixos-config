# NixOS Recovery: Emergency Mode Setelah Dualboot Windows (GPT Corrupt)

> Troubleshooting: NixOS gagal boot dan masuk emergency mode setelah install
> Windows sebagai dualboot di SSD yang sama. Akar masalahnya **GPT primary
> corrupt**, bukan UUID berubah seperti dugaan awal.
>
> Lanjutan dari [nixos-windows-dualboot.md](./nixos-windows-dualboot.md).
> Kejadian & pemulihan: **2026-07-29 → 2026-07-30**.

---

## Ringkasan

| | |
|---|---|
| **Gejala** | Boot nyangkut di `Timed out waiting for device /dev/disk/by-uuid/...`, lalu masuk **emergency mode** dengan `root account is locked`. |
| **Dugaan awal** | UUID root partition berubah gara-gara GParted. **(Salah)** |
| **Akar masalah** | **GPT primary table corrupt** akibat Windows installer menulis partisi. Backup GPT masih sehat. |
| **Solusi** | Rebuild GPT primary dari backup (via `gdisk`), lalu regenerate bootloader NixOS. |
| **Data** | Aman 100% — tidak ada partisi hilang, hanya "daftar isi" disk yang rusak. |

---

## Setup / Kondisi

- Satu SSD NVMe (**Phison ESO512GHLCA1-E9C**, 476.9 G) berisi **NixOS + Windows**.
- NixOS di-install lebih dulu; Windows menyusul, mengisi 68.4 GiB unallocated
  yang dibuat via GParted.
- Root account emergency shell terkunci → **wajib recovery dari luar (live USB)**.
- Tools recovery: Raspberry Pi (Ubuntu) untuk flashing + flashdisk **Ventoy** +
  ISO NixOS x86_64.

> ## ⚠️ Nama `nvmeXn1` TIDAK STABIL di mesin ini
>
> Selama sesi ini saja nama device bertukar **tiga kali**. Contoh nyata:
>
> | Momen | Phison (NixOS+Windows) | TEAM (data `/mnt/doc`) |
> |---|---|---|
> | Sebelum shrink | `nvme1n1` | `nvme0n1` |
> | Setelah recovery | `nvme0n1` | `nvme1n1` |
>
> **Selalu** konfirmasi lewat MODEL sebelum perintah destruktif:
>
> ```fish
> lsblk -o NAME,MODEL,SIZE
> ```
>
> Semua contoh di bawah memakai `/dev/nvme0n1` karena itu nama Phison **saat
> recovery dilakukan**. Ganti dengan nama yang sesuai di sesimu.

### Layout partisi final (terverifikasi 2026-07-30)

| Partisi | Ukuran | Isi |
|---|---|---|
| `p1` | 1 G | EFI System (`/boot`) — **dipakai bersama NixOS + Windows** |
| `p2` | 398.8 G | Root NixOS (ext4, label `root`) |
| `p3` | 16 M | Microsoft reserved (MSR) |
| `p4` | 67.5 G | Windows C: (NTFS) |
| `p5` | 849 M | Windows recovery (NTFS) |
| `p6` | 8.8 G | Linux swap |

---

## Diagnosis

Diagnosis yang benar ketemu lewat proses eliminasi:

1. **Boot generation lama juga gagal** (turun 4 generasi tetap stuck) →
   menyingkirkan "config generation terbaru rusak". Kalau semua generation
   menunjuk device yang sama dan sama-sama gagal, masalahnya di **device**,
   bukan config.
2. **`lsblk -f` tidak menampilkan partisi NixOS sama sekali** → device-nya
   memang tidak terbaca kernel. Sempat memicu kekhawatiran partisi terhapus.
3. **`fdisk -l /dev/nvme0n1`** memunculkan pesan kunci:
   ```
   The primary GPT table is corrupt, but the backup appears OK, so that will be used.
   ```
   → Inilah akar masalahnya. Partisi **utuh**, tapi GPT header primary rusak,
   jadi kernel tidak bisa membaca tabel partisi → device root tidak ketemu saat
   boot.

**Pelajaran:** jangan mengunci diagnosis di awal. Dugaan pertama (UUID berubah)
ternyata salah; `fdisk`/`gdisk` yang mengungkap kondisi sebenarnya.

---

## Prosedur Recovery

### Fase 0 — Siapkan Live USB (di device lain)

Karena emergency shell terkunci, boot dari live USB NixOS.

- Flashdisk sudah **Ventoy** → **tidak perlu `dd`**. Cukup copy ISO ke partisi
  Ventoy; Windows ISO yang sudah ada di situ tidak terganggu.
- ISO **wajib x86_64/amd64** (bukan aarch64/ARM), walaupun di-flash dari Raspi
  ARM, karena yang di-boot adalah PC x86.
- Setelah copy ISO, **`sync`** dulu sebelum cabut (file besar sering masih
  nyangkut di write cache):

  ```bash
  sync
  sudo umount /media/<user>/Ventoy
  ```

Boot PC dari Ventoy → pilih ISO NixOS.

### Fase A — Perbaiki GPT

> Semua langkah menulis ulang **tabel partisi saja**; isi partisi tidak disentuh.

**1. Backup GPT existing (safety net):**

```bash
sudo sgdisk --backup=/tmp/nvme0n1-gpt-backup.bin /dev/nvme0n1
ls -lh /tmp/nvme0n1-gpt-backup.bin
```

> `/tmp` di live env = RAM, hilang saat reboot. Cukup untuk proteksi selama
> proses. Untuk permanen, copy ke Ventoy atau ke `/mnt/doc`.

**2. Verifikasi kondisi (read-only):**

```bash
sudo sgdisk --verify /dev/nvme0n1
```

Output khas:
```
Main partition table: ERROR
Backup partition table: OK
MBR: protective          # (bukan hybrid — aman, MBR tak perlu disentuh)
```

**3. Rebuild via `gdisk` interaktif** (lebih aman daripada `sgdisk` sekali-jalan
saat ada warning overlap):

```bash
sudo gdisk /dev/nvme0n1
```

Di dalam gdisk, jalankan berurutan:

| Input | Aksi |
|---|---|
| `r` | Masuk **recovery/transformation menu** (pastikan prompt berubah jadi `Recovery/transformation command`) |
| `c` | Load **backup partition table** ke main (jawab `Y` saat konfirmasi) |
| `v` | Verify → target: **`No problems found.`** |
| `w` | **Write** ke disk (jawab `Y`). Warning "THIS WILL OVERWRITE EXISTING PARTITIONS" hanya berarti menulis ulang tabel, bukan menghapus isi. |

> Sampai menekan `w`, **belum ada apa pun yang tertulis**. `q` = quit aman tanpa
> menyimpan.

**4. Refresh & konfirmasi:**

```bash
sudo partprobe /dev/nvme0n1
lsblk                              # semua p1..p6 harus muncul kembali
sudo sgdisk --verify /dev/nvme0n1  # target: No problems found
```

> Warning "gap between main metadata and main partition table" itu **normal**
> untuk NixOS — abaikan.

### Fase B — Mount sistem NixOS

```bash
sudo mount /dev/nvme0n1p2 /mnt        # root
ls /mnt                               # cek: ada etc, nix, home, boot, dst
sudo mount /dev/nvme0n1p1 /mnt/boot   # EFI/boot
ls /mnt/boot                          # cek: ada EFI, loader
```

### Fase C — Regenerate bootloader

```bash
sudo nixos-enter --root /mnt          # prompt jadi [root@nixos:/]#
```

Idealnya:
```bash
nixos-rebuild boot
```

**Kalau terhalang "need internet connection"** (padahal config tidak berubah,
jadi internet sebenarnya tidak perlu), pakai jalur **generation yang sudah
ter-build** — dijamin offline:

```bash
# cek generation aktif
ls -la /nix/var/nix/profiles/system*
# system -> system-NN-link menandakan generation terbaru

# install bootloader dari generation aktif, tanpa evaluasi ulang / tanpa internet
/nix/var/nix/profiles/system/bin/switch-to-configuration boot
```

Output sukses (contoh):
```
Skipping "/boot/EFI/systemd/systemd-bootx64.efi", same boot loader version in place already.
```
Pesan "Skipping ... same version" = **positif**, bootloader sudah terpasang benar.

### Fase D — Keluar & reboot

```bash
exit                    # keluar chroot
sudo umount -R /mnt     # unmount rekursif (boot lalu root)
sudo reboot
```

**Cabut flashdisk Ventoy saat layar restart** agar tidak boot balik ke installer.

---

## Hasil

- NixOS boot normal (Hyprland), **tanpa error UUID**.
- Dualboot berfungsi; data kedua OS utuh.

### Boot order: Windows merebut default

Windows installer menyetel dirinya **default #1** di boot order UEFI, jadi PC
langsung ke Windows dan butuh F12 manual untuk memilih NixOS.

Kondisi tepat setelah install (`efibootmgr`, terverifikasi 2026-07-30):

```
BootCurrent: 0003
BootOrder: 0004,2002,2003,0003,2001,0001      ← 0004 (Windows) di depan
Boot0003* Linux Boot Manager    HD(1,GPT,9f5f4e04-…-889f585cece3,…)/\EFI\systemd\systemd-bootx64.efi
Boot0004* Windows Boot Manager  HD(1,GPT,9f5f4e04-…-889f585cece3,…)/\EFI\Microsoft\Boot\bootmgfw.efi
```

Perhatikan **GUID partisi kedua entry identik** (`9f5f4e04-…`) — bukti Windows
menulis ke ESP yang **sama**, bukan bikin ESP sendiri. Itu kondisi yang
diinginkan: systemd-boot otomatis mendeteksi Windows.

**Fix permanen** — taruh `0003` di depan, sisanya urutan lama dipertahankan:

```fish
sudo efibootmgr -o 0003,0004,2002,2003,2001,0001
```

Verifikasi:
```fish
sudo efibootmgr | head -3        # BootOrder harus mulai dengan 0003
sudo bootctl list | grep -i title # harus memuat "Windows Boot Manager"
```

> Nomor `BootXXXX` Windows **tidak selalu 0000**. Di mesin ini dia dapat `0004`.
> Selalu baca ulang `efibootmgr -v` setelah install, jangan hafalkan angkanya.

Alternatif tanpa CLI: masuk BIOS/UEFI (`F2`) → **Boot Order** → naikkan
**"Linux Boot Manager"** di atas Windows → save & exit.

### Menu boot kepanjangan

Setelah dualboot, `Windows Boot Manager` muncul di **paling bawah** menu
systemd-boot — dan menu di mesin ini sempat berisi **66 generation NixOS**,
jadi harus scroll jauh. Dibatasi lewat `modules/bootloader.nix`:

```nix
boot.loader.systemd-boot.configurationLimit = 10;
```

Ini hanya membatasi entry yang **ditampilkan**; generation lama tetap ada di
`/nix/var/nix/profiles` dan tetap bisa di-rollback dari CLI.

> Catatan: `boot.loader.grub.useOSProber` **tidak berlaku** di sini. os-prober
> itu khusus GRUB, sedangkan setup ini pakai systemd-boot — yang menemukan
> `bootmgfw.efi` di ESP bersama tanpa bantuan apa pun.

---

## Pencegahan

### 1. Pasang tool recovery permanen

Kalau GPT rusak lagi, kemungkinan besar kamu **tidak bisa boot** untuk sekadar
`nix-shell`. Jadi pasang permanen di `modules/package.nix`:

```nix
efibootmgr
parted
gparted
gptfdisk    # menyediakan sgdisk, gdisk, cgdisk, fixparts
```

### 2. Backup GPT ke lokasi permanen

Recovery kemarin berhasil karena backup GPT kebetulan sehat. Jangan bergantung
pada keberuntungan:

```fish
lsblk -o NAME,MODEL,SIZE     # pastikan mana yang Phison
sudo sgdisk --backup=/mnt/doc/nvme-gpt-backup-(date +%Y%m%d).bin /dev/nvme0n1
```

Ukurannya ~17 KB (512 B protective MBR + 512 B header + 16 KB entry array).
Cek validitasnya — offset 512 harus berisi signature `EFI PART`:

```fish
od -A d -c -j 512 -N 8 /mnt/doc/nvme-gpt-backup-*.bin
# 0000512   E   F   I       P   A   R   T
```

Restore (dari live USB):
```fish
sudo sgdisk --load-backup=/mnt/doc/nvme-gpt-backup-YYYYMMDD.bin /dev/nvmeXn1
```

> Simpan di `/mnt/doc` (NTFS bersama) supaya bisa diambil dari Windows **maupun**
> live USB saat NixOS tidak bisa boot.

### 3. Matikan Fast Startup di Windows

Wajib. Tanpa ini Windows meng-hibernate filesystem-nya, NTFS ditandai dirty, dan
`/mnt/doc` jadi read-only / gagal mount dari NixOS.

**Control Panel → Power Options → Choose what the power buttons do → Change
settings that are currently unavailable →** uncheck **"Turn on fast startup"**.

### 4. Samakan jam

```
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```

---

## Poin Penting (TL;DR)

1. **Emergency mode + "timed out waiting for device"** setelah utak-atik partisi
   → curigai **GPT corrupt**, jangan langsung asumsi UUID berubah. Cek dengan
   `fdisk -l` / `sgdisk --verify`.
2. **GPT punya backup.** Kalau primary rusak tapi backup OK, tinggal
   `gdisk` → `r` → `c` → `v` → `w`. Non-destruktif ke data.
3. **Ventoy** = tinggal copy ISO, tidak perlu `dd`. Selalu `sync` sebelum cabut.
4. **`switch-to-configuration boot`** dari generation ter-build = cara regenerate
   bootloader **tanpa internet**, saat `nixos-rebuild boot` ngotot minta koneksi.
5. Setelah dualboot, **atur boot order UEFI** agar Linux Boot Manager jadi
   default. Nomor entry Windows tidak bisa ditebak — baca `efibootmgr -v`.
6. **Kerusakan GPT itu peristiwa sekali-install.** Boot bolak-balik
   Windows ↔ NixOS tidak menyentuh tabel partisi. Yang justru berulang adalah
   Fast Startup dan Windows major update merebut `BootOrder`.
7. **Jangan percaya nama `nvmeXn1`.** Selalu verifikasi lewat MODEL.
