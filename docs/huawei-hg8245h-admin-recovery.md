# Case Study: Recovery Akses Admin Huawei HG8245H (Lupa Password)

> Lab pribadi — router milik sendiri (192.168.100.1). Tujuan: belajar
> web admin panel testing, unauthorized access, dan brute-force attack
> tanpa menyentuh hardware (no reset, no UART).

## 1. Skenario

- Perangkat: Huawei HG8245H (ONT IndiHome), firmware `V3R017C10S105`,
  hardware `BE9.E`, `CfgMode = INATELKOM`.
- Password admin web diganti saat setup awal (oleh orang lain, lupa).
- Default `admin/admin`, `telecomadmin/admintelecom` sudah tidak berlaku.
- Kendala: tidak bisa cek history laptop lama (rusak).

## 2. Reconnaissance

### Port scan

```
$ nmap -Pn -p 21,22,23,53,80,443,8080,8443,7547,30005,9999 192.168.100.1

23/tcp open  telnet     <-- attack surface utama
80/tcp open  http
21,22,443,7547,8080...  filtered (firewall)
```

### Anatomi halaman login web

Dari view-source `http://192.168.100.1/` dan `/resource/common/safelogin.js`:

- Variabel server-side di-render ke JS: `FailStat`, `LoginTimes`,
  `LockLeftTime`, `errloginlockNum = 3`, `LockTime = 60`,
  `errVerificationCode` (captcha, nonaktif saat 0).
- Alur login (untuk `CfgMode != DT/TRIPLET`):

  1. `POST /asp/GetRandCount.asp` → token acak (`cnt`), diawali BOM.
  2. Browser set cookie `Cookie=body:Language:english:id=-1`.
  3. `POST /login.cgi` dengan:
     - `UserName` = plaintext
     - `PassWord` = **base64(password)** — bukan hash, hanya encoding
     - `x.X_HW_Token` = `cnt` (anti-CSRF, token sekali pakai)
- Response **gagal**: halaman "Waiting..." berisi
  `var pageName = '/'; top.location.replace(pageName);`
  dan counter `LoginTimes` bertambah.
- `RndSecurityFormat()` = implementasi SHA-256 (dipakai untuk mode `DT`,
  tidak dipakai di firmware INATELKOM ini).

### Perilaku lockout (diukur eksperimen)

| Percobaan         | LoginTimes | LockLeftTime | Keterangan                                   |
| ----------------- | ---------- | ------------ | -------------------------------------------- |
| Gagal ke-1        | 1          | ~57s         | timer mulai                                  |
| Gagal ke-2        | 2          | ~54s         | masih boleh mencoba                          |
| Gagal ke-3        | 3          | ~58s         | login.cgi**mengabaikan** attempt baru  |
| Attempt saat lock | tetap 3    | terus turun  | tidak menambah counter, tidak me-reset timer |

Counter `LoginTimes` baru reset ke 0 sekitar **±2 menit** setelah
kegagalan terakhir (bukan tepat saat `LockLeftTime` habis).

**Rate efektif brute-force: 3 percobaan per ~2 menit (±90/jam).**

## 3. Temuan Kunci: Telnet Terbuka + Kredensial Default

Port 23 (telnet) terbuka dan **password telnet tidak pernah diganti**,
meskipun password web sudah diganti:

```
Login: root
Password: adminHW        # default pabrik HG8245H
Password is default value, please modify it!
WAP>
```

Pelajaran penting: **kredensial web dan telnet adalah database terpisah**.
Mengganti password web admin tidak mengubah password telnet.

### Eskalasi di ATP CLI

```
WAP> su
success!
SU_WAP> shell
WAP(Dopra Linux) #        # shell jailed — semua perintah ditolak:
                          # ls, cat, grep, tftp, echo -> "Command is not existed"
```

Perintah ATP yang berguna:

| Perintah                   | Hasil                                                                                                              |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `?`                      | daftar lengkap perintah ATP                                                                                        |
| `display version`        | firmware`V3R017C10S105`                                                                                          |
| `su`                     | mode superuser tanpa password tambahan                                                                             |
| `wap ps`                 | process list — terlihat`dropbear` (SSH) & `http-server` berjalan tapi di-firewall                             |
| `display file <path>`    | ada, tapi menolak semua path yang dicoba (`/mnt/jffs2/hw_ctree.xml` dll) — filesystem pakai UBIFS, path berbeda |
| `set userpasswd <user>`  | mengubah password user CLI, tapi**meminta old password** — tidak bisa dipakai tanpa tahu password lama      |
| `backup cfg by tftp ...` | tidak ada di firmware ini                                                                                          |
| `diagnose`               | hanya debugging paket (dhcp/dns/pppoe)                                                                             |

### Buntu di jalur konfigurasi

- Shell Dopra sepenuhnya jailed (full path `/bin/ls` pun ditolak).
- Tidak ada cara menarik `hw_ctree.xml` (berisi hash password web,
  `SHA256(MD5(password))`) tanpa TFTP/server FTP yang aktif.
- SSH (dropbear) berjalan tapi port 22 di-filter firewall; membukanya
  butuh modifikasi firewall rule — tidak dilanjutkan (side effect).

## 4. Brute-Force Web Login (Rate-Limited)

Strategi: wordlist kecil ter-target (bukan brute force karakter murni —
tidak mungkin dengan rate 90/jam), hormati lockout, deteksi sukses dari
anomali response.

Wordlist batch 1: 110 kandidat — default Huawei/IndiHome +
pola `kata+angka` (`admin123`, `indihome123`, `123admin`, `wifi2024`, ...).

Log tersimpan di `/tmp/brute_admin.log`, format:
`[timestamp] TRY <password> -> fail|maybe-success`.

## 5. Script

### 5.1 Tes login telnet (`telnet_try.py`)

Menangani negosiasi IAC telnet secara manual (Python 3.13+ tidak punya
`telnetlib`), mengirim user/password, mengklasifikasikan hasil:

```python
# inti: read_until() mem-filter IAC/DO/WILL dan menjawab WONT/DONT
# usage: python3 telnet_try.py 192.168.100.1 root adminHW
```

(lihat `/tmp/telnet_try.py` saat sesi lab berlangsung)

### 5.2 Runner perintah ATP (`telnet_cmd.py`)

Login → kirim daftar perintah → baca output sampai prompt `WAP>` muncul
lagi. Dipakai untuk semua eksplorasi `su`, `wap ps`, `display *`.

### 5.3 Brute-forcer web (`brute_web.py`)

Replika alur login JS dalam Python murni (stdlib saja):

```python
cnt = POST("/asp/GetRandCount.asp").lstrip("\ufeff").strip()
body = POST("/login.cgi", {
    "UserName": user,
    "PassWord": base64(password),
    "x.X_HW_Token": cnt,
})
# gagal  : body mengandung pageName = '/'
# sukses?: apapun selain itu -> berhenti & laporkan
```

- Sebelum tiap attempt, baca `LoginTimes`/`LockLeftTime` dari `GET /`;
  tidur saat `LoginTimes >= 3`.
- Resume otomatis: kandidat yang sudah tercatat di log dilewati.
- Jalankan: `python3 brute_web.py 192.168.100.1 admin wordlist.txt log.txt`

### 5.4 Generator wordlist batch 2 (`gen_wordlist.py`)

Batch 2 = kandidat ter-target dari identitas unit ini (hasil recon §8.7),
bukan pola generik. Sumber:

- **Serial** `2150083398EGJA001596` → full, suffix `EGJA001596`, `001596`,
  `1596`, head `2150083398`, mfg suffix `C402`.
- **MAC** `28:9E:97:F4:2C:E4` → `289E97F42CE4`, last6 `F42CE4`, last4 `2CE4`.
- **Default superadmin terpublikasi** → `superadmin`, `Admin@123`,
  `Support#123`, `telkomadmin`, dst.
- Kombinasi `prefix+token` (`admin001596`, `F42CE4admin`, ...).

Menghasilkan **70 kandidat fresh** (auto-dedupe vs log lama) →
`/tmp/wordlist_serial.txt`. Dijalankan **target `telecomadmin` lebih dulu**
(hipotesis: hanya akun `admin` yang diganti), log `brute_telecomadmin.log`.

## 6. Deteksi & Mitigasi (Sisi Defensive)

1. **Ganti password telnet** — akar masalah kasus ini. Dari ATP:
   `set userpasswd root` (perlu password lama).
2. Matikan telnet sama sekali kalau tidak dipakai; jangan andalkan
   "password web sudah diganti".
3. Lockout 3x/60s **efektif** membatasi brute force online menjadi
   ±90 percobaan/jam — wordlist besar tidak praktis. Namun tidak
   melindungi dari kredensial default di service lain.
4. Captcha (`errVerificationCode`) aktif setelah beberapa kegagalan di
   sebagian firmware — lapisan tambahan.
5. Monitoring: `LoginTimes`/`FailStat` ter-render di halaman login —
   bisa dipakai canary sederhana untuk mendeteksi percobaan brute force.
6. Segmentasi: service manajemen (telnet/SSH/TR-069) idealnya tidak
   ter-expose ke semua klien LAN.

## 7. Timeline Singkat

1. `curl` landing page → identifikasi `CfgMode=INATELKOM`, lockout 3x/60s.
2. `nmap` → telnet terbuka.
3. Brute kecil manual kredensial default telnet → **`root/adminHW` masuk**.
4. Eksplorasi ATP CLI (`su`, `shell`, `display *`, `wap ps`) → shell jailed,
   ekstraksi config buntu.
5. Ukur perilaku lockout web secara eksperimen.
6. Tulis brute-forcer rate-limited → jalankan wordlist ter-target di background.

## 8. Sesi Lanjutan: Uji Jalur Alternatif (via root telnet)

> Premis: brute web (90/jam) itu jalur terlemah. Kita sudah pegang root
> telnet + `su`, jadi seharusnya ada jalan lebih cepat. Sesi ini menguji
> jalur-jalur "lebih gg" secara sistematis. Hasilnya: mayoritas buntu,
> tapi buntu-nya sekarang **terbukti**, bukan asumsi.

### 8.1 Enumerasi penuh command ATP (361 command)

`?` di prompt `WAP>` → 361 command (tersimpan `/tmp/atp_cmds.txt`). Ini
whitelist registry tetap, bukan shell. Yang relevan untuk recovery:
`ping`, `traceroute`, `ifconfig`, `set userpasswd`, `display file`,
`display lastword`, `load ssh-pubkey`, `ssh authentication-type`,
`make ssh hostkey`, `save data`, `collect debug info`,
`restore manufactory`. Tidak ada `set webpasswd` / `add user` /
`backup cfg` / `upload cfgfile`.

### 8.2 Command injection `ping`/`traceroute` → GAGAL (input divalidasi)

Vektor injeksi klasik HG8245 sudah ditutup di firmware `V3R017C10S105`:

```
WAP> ping 127.0.0.1;id            -> ERROR::Input para is not right
WAP> ping 127.0.0.1 -c 1 && ls    -> ERROR::Input para is not right
WAP> ping "127.0.0.1|id"          -> ERROR::Input para is not right
WAP> traceroute 127.0.0.1;id      -> ERROR::Input para is not right
```

Argumen divalidasi sebagai IP **sebelum** diteruskan ke `system()`.
`;`, `|`, `&&`, backtick, quote — semua ditolak. Break-out via diag: mati.

### 8.3 Tidak ada passthrough busybox — Dopra shell = registry

`ifconfig` jalan **hanya** karena masuk whitelist ATP. Command umum ditolak:

```
WAP> id | pwd | ls | cat <path> | busybox | sh   -> ERROR::Command is not existed
```

Dopra shell berbasis registry command, bukan POSIX sh. Konsekuensi:
tidak ada builtin → trik bypass jail POSIX (glob `echo /mnt/jffs2/*`,
`while read l; do echo "$l"; done < file`) **tidak berlaku** di sini.
Ini menutup celah yang biasanya bisa dump file tanpa `cat`.

### 8.4 `set userpasswd` tetap minta `old password:` (bahkan dalam `su`)

Harapan: superuser bisa set password akun lain tanpa password lama.
Kenyataan:

```
WAP> su
SU_WAP> set userpasswd admin
old password:                     # <- tetap minta, su TIDAK mem-bypass
```

Reset akun tanpa tahu password lama: mentok, termasuk sebagai superuser.

### 8.5 `display file` bukan file-reader umum

Menolak semua path & direktori yang dicoba:

```
display file /              -> ERROR::The directory or file is wrong!
display file /mnt/jffs2     -> ERROR::The directory or file is wrong!
display file .../hw_ctree.cfg, /var/hw_ctree.xml, ... -> semua ditolak
display file ?              -> cuma echo "display file" (tanpa daftar file sah)
```

Hanya menerima whitelist file internal tertentu (kemungkinan log), bukan
config. Exfil `hw_ctree.xml` via CLI: **terkonfirmasi buntu** (lebih tuntas
dari sesi sebelumnya — sekarang dir listing pun ditolak).

### 8.6 Jalur SSH pubkey — ada, tapi tidak menolong

```
display ssh authentication-type   -> mode 0 (password auth)
display ssh-hostkey fingerprint   -> md5 2f:1c:34:c9:4c:56:12:6c:...
```

Command `load ssh-pubkey` + `ssh authentication-type` + `make ssh hostkey`
memungkinkan daftarkan pubkey & aktifkan key-auth. Tapi: (a) port 22
di-firewall (dari §2), (b) dropbear kemungkinan mendarat di ATP jail yang
sama, bukan root shell Linux. Jadi tidak menambah kapabilitas — dilewati.

### 8.7 Recon tambahan yang berguna

- `ifconfig` → MAC ONT `28:9E:97:F4:2C:E4`, br0=192.168.100.1,
  gem1 (uplink GPON), lan1-4, eth0. Uptime 65 hari.
- `display deviceInfo` → **Serial `2150083398EGJA001596`**,
  ManufactureInfo `...C402`, ReleaseTime `2017-05-12`, chip `00060020180509`.
- `display lastword` → ring-buffer trace membocorkan nama modul internal
  (`hw_http_server.c`, `hw_web_auth.c`, `hw_cli_user.c`, `hw_os_fileio.c`).
  Recon arsitektur; tidak ada kredensial.

## 9. Peta Jalur: Mana Buntu, Mana Hidup

| Jalur                                     | Status            | Alasan                                          |
| ----------------------------------------- | ----------------- | ----------------------------------------------- |
| Command injection ping/traceroute         | ❌ buntu          | input divalidasi sebelum`system()`            |
| Escape jail via builtin shell (glob/read) | ❌ buntu          | Dopra registry, bukan POSIX                     |
| `set userpasswd` (reset akun web)       | ❌ buntu          | minta old password, su tak bypass               |
| Exfil`hw_ctree.xml` (`display file`)  | ❌ buntu          | reader whitelist, tolak semua path              |
| Exfil via TFTP/FTP                        | ❌ buntu          | tidak ada command backup/upload di firmware ini |
| SSH pubkey → root shell                  | ❌ buntu          | port 22 firewall + kemungkinan jail sama        |
| Crack hash offline                        | ⛔ terblokir      | butuh exfil config (semua jalur exfil buntu)    |
| **Root telnet (root/adminHW)**      | ✅**hidup** | kontrol penuh device via ATP CLI                |
| Brute web rate-limited                    | 🟡 lambat         | 90/jam; satu-satunya jalur ke password web asli |
| `restore manufactory` (factory reset)   | 🚫 dihindari      | melanggar constraint no-reset                   |

## 10. Rekomendasi Aksi

1. **Reframe tujuan.** "Kontrol admin device" **sudah tercapai** via root
   telnet — WiFi, PPPoE, port-forward, VLAN, dsb bisa diubah lewat command
   ATP yang sesuai. Web GUI bukan satu-satunya bidang kontrol; password web
   asli hanya perlu kalau memang wajib lewat GUI.
2. **Kalau tetap butuh password web:** brute tetap satu-satunya jalur bersih
   tanpa reset — tapi perkecil ruang, jangan wordlist buta:

   - Tambah kandidat turunan **serial**: `2150083398EGJA001596`,
     `EGJA001596`, `001596`; dan **MAC**: `289E97F42CE4`, `F42CE4`
     (beberapa batch IndiHome menurunkan superadmin dari serial/MAC).
   - **Target `telecomadmin` juga**, bukan cuma `admin` — DB akun terpisah,
     bisa jadi hanya `admin` yang diganti.
   - Pertahankan rate limiter §4 (3/2menit) supaya tidak lockout permanen.
3. **Crack offline hanya jika** ketemu jalur exfil baru (mis. firmware update
   yang membuka TFTP, atau bug `display file` pada versi lain). Di firmware
   ini: tidak tersedia.
4. **Reset fisik = pilihan terakhir**, dan hanya kalau GUI benar-benar wajib.
   Trade-off: kehilangan config PPPoE/VLAN IndiHome (perlu re-provisioning).
