# FinBro — Project Status

Date: 7 Oktober 2026 · Version 1.0.0+1 · `id.finbro.app`

**Status:** tidak ada target rilis; app dijaga tetap siap rilis. Validasi perangkat setelah perubahan 2–7 Okt belum tuntas; lihat daftar pemeriksaan di bawah.
Sesi 7 Okt lanjutan (fitur yang ditunda, atas keputusan owner): **OCR untuk PDF mutasi hasil scan** (Android, ≤30 halaman), **proses latar belakang WorkManager** (tiap ~6 jam: recurring + auto-confirm + alert budget, jadwal daily check, widget, backup folder), **enkripsi database SQLCipher** (kunci per perangkat; migrasi plaintext aman terhadap kunci yang belum tersimpan; layar error dengan "Mulai dengan database baru"). Juga: salinan backup folder ditulis sebagai `.partial` lalu di-rename; restore `.finbro` memakai kunci backup bila perangkat belum punya; entrypoint widget headless diperbaiki (dicari lewat URI library). Cloud sync: owner memutuskan belum dikerjakan. `flutter analyze` bersih; full suite **354 lulus**.
Sesi 7 Okt pagi (sinkronisasi dokumen ↔ kode): **FAB (+) Home dan Transaksi** kini benar-benar di atas navbar (dulu `Transform.translate(-58)` masih tertutup ±10 dp, lebih parah dengan inset navigasi sistem); shell menerbitkan tinggi penuh navbar (`_NavBarScope`) untuk `AboveNavBar`/`navBarClearance`, regresi di `test/app/shell_fab_test.dart`. **Widget** dimatangkan: engine headless dulu tidak punya handler `render` (widget tak pernah menerima data) — kini terdaftar; selagi app hidup `WidgetSync` menghitung di koneksi app sendiri setelah tulis ke `accounts`/`transactions`/`exchange_rates`/`app_settings` + saat start/resume (sebelumnya hanya commit ledger, sehingga saldo awal akun, kurs, restore, onboarding tidak ter-update); caption bertanggal, mask "Saldo disembunyikan" terpisah dari "Terkunci", DB tidak dibuat oleh widget sebelum onboarding, ukuran benar 4×1. Fitur yang diklaim dokumen tetapi belum lengkap kini diselesaikan: **UI backup terenkripsi ke folder + restore `.finbro`** (format v2 ter-chunk, streaming), **multi-currency di input/tampilan transaksi** (form, daftar, detail, PDF, CSV, filter nominal), **validasi/pembuatan backup streaming per entri di isolate**. Suite saat itu **331 lulus**.
Sesi 3 Okt (roadmap): multi-currency (skema v5), widget home screen, impor statement PDF. Suite saat itu 312 (widget 4, mata uang 37, PDF 11).
Sesi 3 Okt 2026 (backup): backup/restore streaming — zip ditulis/dibaca via file (batas 512 MB zip / 256 MB per entry / 1 GB total sebagai batas ukuran file). `validateFile` memverifikasi CRC per entri, nama aman, checksum SHA-256 DB & lampiran. Hash PIN terikat Android Keystore (HMAC non-ekspor, constant-time, fail-explicit) selesai. Lapisan domain backup terenkripsi folder dibuat (UI + restore `.finbro` baru tersambung 7 Okt; staging per entri yang benar-benar streaming + isolate juga 7 Okt).
Sesi 2 Okt 2026: fitur impor mutasi bank CSV selesai end-to-end (parser, UI tinjau, duplikat, commit, route `/import`, 6 test) — tidak perlu dikerjakan ulang; lihat Roadmap untuk sisa PDF. Checksum lampiran backup selesai: SHA-256 per lampiran di manifest + verifikasi restore + `file_sha256` (skema v4) di integrity check.

## Verified

- `flutter analyze`: no issues. Full test suite passed: **355 tests** (7 Okt 2026, setelah OCR PDF/WorkManager/SQLCipher dan uji emulator). Sebelumnya: 331 (7 Okt pagi), 312 (3 Okt), 259 (streaming backup, PIN Keystore).
- Diverifikasi di perangkat 1 Okt (sebelum perubahan 2–3 Okt), release build di Xiaomi 14T (Android 16 / HyperOS):
  - Onboarding, income/expense/transfer, edit/delete, transfer, budget alert 85%, konfirmasi gaji recurring.
  - Notifikasi: budget alert, reminder gaji, daily check (juga layar mati), "Nanti" +1 jam, "Tidak ada" dari background isolate; alarm dipulihkan setelah reboot.
  - OCR (struk sintetis Indomaret, screenshot GoPay), crop, peringatan duplikat.
  - PDF bulanan, CSV, backup ke Downloads, restore 1200 transaksi ≈5 dtk.
  - App lock PIN + prompt biometrik; offline penuh; font 200% dan 720×1280.
  - Performa (1200 transaksi): launch 344–386 ms, scroll ≈85–100 fps, PSS ≈200 MB.

## Perlu dicek ulang di perangkat (berubah 3–7 Okt)

- **Multi-currency**: buat akun USD + kurs di form akun; catat pengeluaran 12,50 di akun USD → tampil `$12,50` di Transaksi/detail/akun, total harian & total saldo ≈Rp; edit kurs di Pengaturan → Kurs Mata Uang; transfer hanya menawarkan akun bermata uang sama.
- **Widget home screen**: tambah widget (4×1), saldo + "Diperbarui <tgl> <jam>" tampil; aktifkan PIN → `•••••• Terkunci`; sembunyikan saldo di Home → `•••••• Saldo disembunyikan`; catat transaksi/ubah saldo awal/kurs → widget ter-update; tutup app → update 30 menit dari engine headless (log `FinBroWidget`).
- **FAB (+) Home & Transaksi**: berada di atas navbar dan bisa ditekan di perangkat dengan navigasi gestur maupun 3 tombol.
- **Backup terenkripsi ke folder**: pilih folder, atur passphrase, Backup sekarang, interval/retensi; restore `.finbro` dengan passphrase benar/salah.
- **Impor PDF**: impor ekspor PDF mutasi bank (text-layer) BCA/Mandiri; PDF berenkripsi meminta kata sandi; PDF hasil-scan dibaca OCR (progress per halaman, Batal), tinjau berlabel "PDF scan (OCR)"; >30 halaman ditolak.
- **WorkManager**: dengan app tertutup, paksa job (`adb shell cmd jobscheduler run -f -n androidx.work.systemjobscheduler id.finbro.app <jobId>`, jobId dari `dumpsys jobscheduler`; WorkManager menunda bila belum lewat 6 jam sejak run terakhir) → recurring auto-confirm terposting, alert budget muncul, widget ter-update; tidak berjalan saat app di layar.
- **SQLCipher**: instalasi baru → header `finbro.sqlite` bukan `SQLite format 3`; update dari APK lama → data tetap ada, `.plain-pending` hilang setelah app dibuka ulang; backup/restore tetap jalan; bila kunci hilang muncul "Data FinBro tidak dapat dibuka" + "Mulai dengan database baru".
- OCR di build release tanpa izin `INTERNET` (PRIV-001).
- Lock: tombol back dan keyboard terblokir saat terkunci; file picker/kamera >5 menit langsung mengunci; relock setelah timeout. Verifikasi PIN setelah binding Keystore (perangkat baru: bind otomatis; update dari versi lama: migrasi saat PIN benar).
- Backup/restore streaming: backup biasa, backup terenkripsi folder, restore dari file & dari folder terenkripsi; pesan error backup terlalu besar; file sisa tidak tertinggal setelah gagal.
- Saldo Home dengan transaksi bertanggal masa depan; Savings Rate dengan aturan baru.
- Tampilan lime accent (revisi UI 1 Okt belum dicek di perangkat).

## Validasi sesi ini

- 7 Okt (emulator Pixel 8 Pro, Android 17, build debug x86_64): onboarding; **FAB (+)** Home dan Transaksi di atas navbar (tepi bawah FAB y=2620, item navbar mulai y=2686 dari 2992) dan tap di tepi bawah FAB membuka form transaksi; **SQLCipher**: instalasi baru terenkripsi (header acak), penanda `.key-unconfirmed` hilang setelah app dibuka ulang, DB plaintext lama (`SQLite format 3`) terenkripsi saat dibuka dengan data utuh dan `.plain-pending` hilang setelah restart, kunci dihapus → layar "Data FinBro tidak dapat dibuka" + "Mulai dengan database baru" (file lama jadi `.unreadable-…`, onboarding ulang); **widget**: pemilih menampilkan 4×1 + deskripsi tanpa angka, setelah dipasang engine headless merender "Rp 1.000.000 · Diperbarui …", sembunyikan saldo → "•••••• Saldo disembunyikan", PIN aktif → "•••••• Terkunci", tap widget membuka app; **WorkManager**: job dipaksa → `BackgroundSyncWorker` SUCCESS ±1,8 dtk, engine headless membuka DB terenkripsi dan merender widget; **OCR PDF hasil scan**: PDF gambar Mandiri → "PDF scan (OCR)", 3 baris dengan nominal/arah/tanggal benar, impor 3 transaksi (dari sini ditemukan & diperbaiki "08: 02" hasil OCR yang tidak terbaca sebagai jam); **backup folder SAF**: pilih Documents, atur passphrase, Backup sekarang → `finbro-20261007-053438.finbro` (tanpa sisa `.partial`), restore `.finbro` dengan kunci perangkat tanpa prompt → pratinjau → restore berhasil, DB hidup tetap terenkripsi; PIN perangkat tetap aktif setelah restore dan cold start selalu membuka layar PIN dulu.
- 7 Okt lanjutan (emulator yang sama): **multi-currency** — akun Wise USD $100 tampil "≈ Rp 1.625.000", total Rp 3.025.000; expense 12,50 di Wise tampil "-$12,50", total harian "-Rp 203.125" dan Total Balance Rp 2.821.875 (kurs 16.250); transfer dari Wise → "Transfer butuh account lain dengan mata uang yang sama."; ditemukan & diperbaiki: form akun tidak memuat kurs saat ganti mata uang (USD kosong, kurs USD terbawa ke EUR) — setelah perbaikan USD 16250, EUR 17250. **Laporan PDF** Oktober (ringkasan IDR, tren 6 bulan, top expense "$12,50") dan **CSV** (kolom `currency`, `12.50,USD`) tersimpan lewat dialog sistem. **Notifikasi**: alert "Budget Food · Warning — 89% (Rp 223.125 dari Rp 250.000)" muncul setelah expense melewati 85%; dengan izin exact, alarm daily check pindah ke exact (window=0) setelah resume dan "Daily check-in" muncul tepat 20:30 dengan aksi Catat/Tidak ada/Nanti; "Tidak ada" dari notifikasi (isolate latar belakang, DB terenkripsi) menandai 8 Okt "Tidak ada aktivitas" di Kalender. `flutter analyze` bersih; full suite **355 lulus**.
- 7 Okt, **build release (R8, ditandatangani kunci rilis) x86_64 di emulator**: instal bersih + onboarding (SQLCipher + flutter_secure_storage berjalan di build R8); tangkapan layar ADB hitam = `FLAG_SECURE` bekerja (ini juga menjelaskan "screenshot hitam" pada catatan 1–3 Okt, bukan bug); WorkManager dipaksa → `BackgroundSyncWorker` SUCCESS (engine headless, entrypoint `backgroundSyncMain` ditemukan, `done(true)`); OCR PDF hasil scan → "PDF scan (OCR)", 3 baris dengan deskripsi bersih (perbaikan "08: 02" terkonfirmasi), impor berhasil; 34 alarm notifikasi terjadwal tanpa crash; alert "Budget Food · Warning — 90%"; **widget** dipasang dari pemilih → engine headless merender "Rp 2.310.000 · Diperbarui 7 Okt 06:51" (saldo benar), sembunyikan saldo → "•••••• Saldo disembunyikan", tampilkan lagi → angka kembali. Build release pertama gagal karena proses Gradle di-kill OOM (`org.gradle.jvmargs=-Xmx8G` di mesin 7,8 GB), percobaan ulang sukses.
- 7 Okt pagi: `flutter analyze` bersih; full suite 331 lulus (termasuk `test/app/shell_fab_test.dart`, `test/core/widget/`, `test/backup/{encrypted_backup,folder_backup_service}_test.dart`). Regresi FAB gagal dengan angkat konstan (84 dp, lebih tinggi dari `-58` lama): pada inset 34 dp tepi bawah FAB 772,7 vs tepi atas navbar 754,7; lulus setelah angkat memakai tinggi navbar penuh. Render Home 1080×2400 di test memperlihatkan FAB (+) penuh di atas navbar.
- 7 Okt: `./gradlew :app:compileDebugKotlin` dan `flutter build apk --debug` sukses; resource `finbro_widget*` ada di APK. APK release universal (`build/app/outputs/flutter-apk/app-release.apk`, 141,2 MB, arm64/armeabi-v7a/x86_64, `libsqlcipher.so` di ketiganya) dibangun dan tanda tangannya diverifikasi `apksigner` (CN=FinBro, SHA-256 sertifikat `12a40ea6…3fbc02`). Pengujian di HP fisik (Xiaomi 14T) belum dilakukan untuk perubahan 2–7 Okt; pasang APK ini lalu jalankan daftar "Perlu dicek ulang di perangkat".
- Sebelumnya (1–3 Okt): APK release dibangun, ditandatangani, dipasang via ADB; UI release belum disetujui (screenshot ADB hitam karena `FLAG_SECURE` — perilaku yang diharapkan; ponsel kembali ke launcher).
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

- Notifikasi exact (`exactAllowWhileIdle`) hanya bila izin "Alarm & pengingat" diberikan; tanpa izin jatuh ke `inexactAllowWhileIdle` (meleset beberapa menit; "Nanti" sampai +45 mnt).
- `allowBackup=false`. Backup manual (banner pengingat setelah 30 hari) atau otomatis terenkripsi ke folder bila diatur (harian/mingguan, saat app dibuka/resume). Uninstall = data hilang tanpa backup.
- Database terenkripsi SQLCipher (kunci acak per perangkat di penyimpanan berbasis Android Keystore). Backup zip manual dan safety snapshot berisi SQLite plaintext (agar bisa dipulihkan di perangkat lain); backup folder terenkripsi.
- WorkManager bisa ditunda OS (Doze, penghemat baterai, pembatasan OEM); recurring tetap diproses saat app dibuka.

## Keputusan owner (2 Okt 2026)

- Net Amount Saved / Savings Rate = transfer bersih ke account Savings. Kontribusi goal = progres goal, bukan tabungan.
- Model bisnis: gratis penuh untuk sekarang. Kemungkinan berbayar nanti: OCR dan laporan PDF yang bisa dikustomisasi (layout, bentuk, warna).
- Offline-first tetap prinsip utama; sync dilakukan saat ada koneksi/kuota.

## Roadmap

| Item | Status codebase |
|---|---|
| Seed merchant Indonesia dan saran kategori saat scan | Selesai; seed + test di `test/scanner/merchant_seed_test.dart`. |
| Notifikasi exact dengan fallback inexact | Selesai di Android; izin `SCHEDULE_EXACT_ALARM`, pengecekan izin, fallback, dan pengaturan sudah ada. Validasi perilaku pada perangkat masih perlu dilakukan. |
| Multi-currency dengan kurs manual | Selesai (3 Okt, dilengkapi 7 Okt): skema v5 `exchange_rates` + enum `Currency` (11 kode), kurs manual di Pengaturan → Kurs Mata Uang, form akun pilih mata uang + kurs; input & tampilan nominal mengikuti mata uang akun (form transaksi/recurring/scan, daftar, detail, PDF, CSV kolom `currency`); semua agregat dan total harian/top expense/filter nominal dikonversi IDR (minor units: IDR/JPY satuan, lainnya sen); transfer hanya antar akun bermata uang sama; test `test/core/{currency_migration,finance_currency,money_format}_test.dart`, `test/features/accounts/account_currency_test.dart`, `test/transactions/{transaction_form_flow,transaction_query}_test.dart`. Validasi perangkat belum. |
| Widget home screen dengan perlindungan lock/sembunyikan saldo | Selesai (3 Okt, dimatangkan 7 Okt): widget 4×1 (`FinBroWidgetProvider.kt`; channel `id.finbro.app/widget` method `render`); selagi app hidup `WidgetSync` (`lib/core/widget/widget_service.dart`) menghitung ulang setelah tulis ke tabel saldo/kurs/pengaturan + start/resume; sistem (pemasangan, tiap 30 menit) memakai engine headless `WidgetCompute` → `widgetBackgroundMain`; PIN aktif → selalu `•••••• Terkunci`, sembunyikan saldo → `•••••• Saldo disembunyikan`; test `test/core/widget/`. Validasi perangkat belum. |
| Impor mutasi bank CSV/PDF dengan review dan deteksi duplikat | CSV selesai (2 Okt): parser 7 preset bank, layar tinjau (`/import`), kategori per baris, deteksi duplikat, sumber `statement_import`. PDF selesai (3 Okt): ekstraksi text-layer pdfrx di isolate, kata sandi 3 percobaan; PDF hasil-scan dibaca OCR (7 Okt, Android, ≤30 halaman); test `test/statement_import/{pdf_statement,scanned_statement_ocr}_test.dart`. |
| Backup terenkripsi ke folder pilihan pengguna (SAF) | Selesai (UI 7 Okt): Backup & Restore → "Backup terenkripsi ke folder" (folder, passphrase, harian/mingguan, simpan 3/5/7/14/30, Backup sekarang, matikan) dan "Restore backup terenkripsi (.finbro)"; format `.finbro` v2 (AES-256-GCM per chunk 1 MiB, Argon2id), enkripsi/dekripsi streaming dari file; test `test/backup/{encrypted_backup,folder_backup_service}_test.dart`. |
| Sinkronisasi cloud offline-first memakai format backup terenkripsi | Belum dikerjakan (keputusan owner 7 Okt: jangan dulu); butuh desain sinkronisasi dan endpoint/penyedia cloud. |
| Proses latar belakang (WorkManager) | Selesai (7 Okt; owner membuka kembali keputusan "tanpa background service"): `BackgroundSyncWorker.kt` periodik 6 jam → `backgroundSyncMain`; test `test/recurring/recurring_concurrency_test.dart`, `test/background/external_writes_test.dart`. Validasi perangkat belum. |
| Enkripsi database (SQLCipher) | Selesai (7 Okt; owner membuka kembali keputusan "tanpa SQLCipher"): `lib/core/database/database_cipher.dart`; test `test/core/database_cipher_test.dart`. APK universal +≈9,5 MiB (unduhan per ABI arm64 +≈1,1 MB). Validasi perangkat belum. |

## Keputusan scope roadmap (2 Okt 2026, dikerjakan 3 Okt)

Disetujui owner dan selesai: impor CSV (2 Okt), backup terenkripsi folder (domain 3 Okt, UI/restore 7 Okt), backup/restore streaming, hash PIN terikat Keystore, retensi safety snapshot, **multi-currency, widget home screen, impor PDF statement** (3 Okt; dilengkapi 7 Okt), **OCR PDF hasil scan, WorkManager, SQLCipher** (7 Okt). Sisa roadmap: cloud sync — owner: jangan dulu.

## Docs

`README.md` (arsitektur, keputusan), `SUMMARY.md` (isi app + change log), `CHANGELOG.md`, `bug.md`, `audit.md`, `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`.
