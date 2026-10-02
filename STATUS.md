# FinBro — Project Status

Date: 2 Oktober 2026 · Version 1.0.0+1 · `id.finbro.app`

**Status:** tidak ada target rilis; app dijaga tetap siap rilis. Validasi perangkat setelah perubahan 2 Okt dan UI release terbaru belum tuntas; lihat daftar pemeriksaan dan hasil sesi di bawah.
Sesi 2 Okt 2026 (terbaru): fitur impor mutasi bank CSV selesai end-to-end (parser, UI tinjau, duplikat, commit, route `/import`, 6 test) — tidak perlu dikerjakan ulang; lihat Roadmap untuk sisa PDF. Checksum lampiran backup juga selesai: SHA-256 per lampiran di manifest + verifikasi restore + `file_sha256` (skema v4) di integrity check — item "Masih terbuka" tinggal backup streaming.

## Verified

- `flutter analyze`: no issues. Full test suite passed: 256 tests (2 Okt 2026, termasuk 6 test impor CSV + 2 test checksum lampiran; skema v4 tersisternisasi).
- Diverifikasi di perangkat 1 Okt (sebelum perubahan 2 Okt), release build di Xiaomi 14T (Android 16 / HyperOS):
  - Onboarding, income/expense/transfer, edit/delete, transfer, budget alert 85%, konfirmasi gaji recurring.
  - Notifikasi: budget alert, reminder gaji, daily check (juga layar mati), "Nanti" +1 jam, "Tidak ada" dari background isolate; alarm dipulihkan setelah reboot.
  - OCR (struk sintetis Indomaret, screenshot GoPay), crop, peringatan duplikat.
  - PDF bulanan, CSV, backup ke Downloads, restore 1200 transaksi ≈5 dtk.
  - App lock PIN + prompt biometrik; offline penuh; font 200% dan 720×1280.
  - Performa (1200 transaksi): launch 344–386 ms, scroll ≈85–100 fps, PSS ≈200 MB.

## Perlu dicek ulang di perangkat (berubah 2 Okt)

- OCR di build release tanpa izin `INTERNET` (PRIV-001).
- Lock: tombol back dan keyboard terblokir saat terkunci; file picker/kamera >5 menit langsung mengunci; relock setelah timeout.
- Backup/restore dengan validasi skema dan batas ukuran baru; pesan error backup terlalu besar.
- Saldo Home dengan transaksi bertanggal masa depan; Savings Rate dengan aturan baru.
- Tampilan lime accent (revisi UI 1 Okt belum dicek di perangkat).

## Validasi sesi ini

- Revisi UI terakhir: active item navbar hanya memakai warna accent pada ikon/teks (tanpa pill); FAB Home dinaikkan dan padding bawah list ditambah setelah pengguna melaporkan FAB tertutup navbar.
- `flutter analyze`: no issues; tiga test terkait lulus. UI perangkat release belum disetujui; screenshot ADB sebelumnya menampilkan hitam dan ponsel kembali ke launcher.
- APK universal release berhasil dibangun dan diverifikasi tanda tangannya, lalu dipasang melalui ADB. Jangan anggap UI release terverifikasi sampai diperiksa ulang di perangkat.
- Flutter Web/Chrome belum berhasil dibangun karena SQLite/Drift memakai `dart:ffi`.

## Validation pending (owner)

- OCR pada struk foto asli dan screenshot e-wallet/bank lain.
- TalkBack.
- Sidik jari (prompt sudah terverifikasi).
- Notifikasi di Doze dalam dan OEM/versi Android lain.

## Release blockers (owner actions, saat rilis)

1. Backup `~/finbro-keys/` ke dua lokasi offline.
2. Host `docs/PRIVACY_POLICY.md` di URL publik dan isi email kontak. Kebijakan harus diperbarui bila sync cloud ditambahkan.
3. Aset Play (feature graphic, screenshot); teks di `docs/PLAY_STORE.md`.
4. Closed test 12+ tester selama 14 hari sebelum Production.

## Reliability gaps

- Notifikasi `inexactAllowWhileIdle` (meleset beberapa menit; "Nanti" sampai +45 mnt).
- `allowBackup=false`, backup manual (banner pengingat setelah 30 hari). Uninstall = data hilang tanpa backup.
- Database tidak terenkripsi (proteksi storage OS + app lock).
- Backup/restore memuat seluruh zip ke memori; maksimal 512 MB.

## Keputusan owner (2 Okt 2026)

- Net Amount Saved / Savings Rate = transfer bersih ke account Savings. Kontribusi goal = progres goal, bukan tabungan.
- Model bisnis: gratis penuh untuk sekarang. Kemungkinan berbayar nanti: OCR dan laporan PDF yang bisa dikustomisasi (layout, bentuk, warna).
- Offline-first tetap prinsip utama; sync dilakukan saat ada koneksi/kuota.

## Roadmap

| Item | Status codebase |
|---|---|
| Seed merchant Indonesia dan saran kategori saat scan | Selesai; seed + test di `test/scanner/merchant_seed_test.dart`. |
| Notifikasi exact dengan fallback inexact | Selesai di Android; izin `SCHEDULE_EXACT_ALARM`, pengecekan izin, fallback, dan pengaturan sudah ada. Validasi perilaku pada perangkat masih perlu dilakukan. |
| Multi-currency dengan kurs manual | Belum dikerjakan. Akun dan seluruh laporan saat ini memakai IDR. |
| Widget home screen dengan perlindungan lock/sembunyikan saldo | Belum dikerjakan. Belum ada Android App Widget/provider. |
| Impor mutasi bank CSV/PDF dengan review dan deteksi duplikat | CSV selesai: parser 7 preset bank, layar tinjau (`/import`, menu Lainnya), kategori per baris, deteksi duplikat, sumber `statement_import`; test di `test/statement_import/`. PDF belum. |
| Backup terenkripsi ke folder pilihan pengguna (SAF) | Selesai; backup terenkripsi folder sudah tersedia. |
| Sinkronisasi cloud offline-first memakai format backup terenkripsi | Belum dikerjakan; butuh desain sinkronisasi dan endpoint/penyedia cloud. |

## Docs

`README.md` (arsitektur, keputusan), `SUMMARY.md` (isi app + change log), `CHANGELOG.md`, `bug.md`, `audit.md`, `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`.
