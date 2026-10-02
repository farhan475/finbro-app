# FinBro — Project Status

Date: 2 Oktober 2026 · Version 1.0.0+1 · `id.finbro.app`

**Status:** semua bug dan temuan audit yang diketahui sudah ditutup di kode (`bug.md`, `audit.md`). Belum ada target rilis; app dijaga tetap siap rilis. Yang tersisa: validasi di perangkat setelah perubahan 2 Okt dan tindakan owner.

## Verified

- `flutter analyze`: no issues. `flutter test`: 212 passing (finance rules, recurring engine incl. reminder diff, backup restore hardening, relock timer, lock gate widget test, cursor pagination, migrations).
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
- "Muat lebih banyak" di Transaksi dan detail account dengan >200 transaksi.

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

## Roadmap (disetujui, belum dikerjakan)

1. Seed merchant Indonesia (Indomaret, Alfamart, GoFood, …) → saran kategori saat scan pertama.
2. Notifikasi exact untuk reminder gaji dan reminder recurring lainnya (`SCHEDULE_EXACT_ALARM`/`USE_EXACT_ALARM` + fallback inexact bila izin ditolak).
3. Multi-currency (account per mata uang, kurs manual karena offline; laporan dalam mata uang utama).
4. Widget home screen (saldo/available to spend; menghormati lock dan "sembunyikan saldo").
5. Impor mutasi bank dari CSV dan PDF (parser per bank, review draft, deteksi duplikat).
6. Backup terenkripsi ke folder pilihan pengguna (SAF), lalu sync cloud offline-first yang memakai format terenkripsi yang sama.

## Docs

`README.md` (arsitektur, keputusan), `SUMMARY.md` (isi app + change log), `CHANGELOG.md`, `bug.md`, `audit.md`, `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`.
