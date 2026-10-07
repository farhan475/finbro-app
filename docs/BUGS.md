# FinBro — Bug & Stability Backlog

Status setelah penyelesaian pekerjaan codebase: lihat item aktif di bawah. `flutter analyze` dan `flutter test`: lihat `STATUS.md` setelah verifikasi.

## Masih terbuka

- Widget: update sistem (dipasang / tiap 30 menit) berjalan sebagai `WidgetRefreshWorker` dengan engine headless yang membuka DB yang sama dengan app; bila gagal, widget menampilkan `Rp ••••••` + "Buka FinBro untuk memperbarui" (tidak pernah angka basi). Di Xiaomi/Oppo/Vivo tanpa Autostart, update saat app ditutup bisa tertahan sampai FinBro dibuka. Pantau log `FinBroWidget`.
- Filter nominal Transaksi membandingkan nilai rupiah (kurs manual); baris struk hasil OCR (subtotal/pajak) tetap rupiah karena tidak terikat akun.
- Sinkronisasi cloud belum dikerjakan (keputusan owner 7 Okt).
- WorkManager dapat ditunda OS (Doze/penghemat baterai/OEM). Bila job sedang menulis backup folder lalu dihentikan, salinan `.partial` tertinggal dan dibersihkan backup berikutnya.
- PDF mutasi yang mencampur halaman teks dan halaman scan hanya memakai text layer.

## Belum divalidasi di perangkat
OCR struk foto asli, TalkBack, sidik jari, notifikasi di Doze dalam/OEM lain, perilaku lock baru (tombol back, fokus keyboard, batas 5 menit file picker), backup/restore streaming dan **backup/restore terenkripsi folder** (UI 7 Okt), **multi-currency** (form transaksi/akun, tampilan native, kurs editor, transfer sama mata uang), **widget home screen** (mask Terkunci / Saldo disembunyikan, update setelah ubah saldo/kurs, update 30 menit, ukuran 4×1), **posisi FAB (+)** Home/Transaksi di atas navbar, **impor PDF statement** termasuk **OCR PDF hasil scan**, **WorkManager** (job berjalan dengan app tertutup), **SQLCipher** (instalasi baru, migrasi dari APK lama, restore).

## Selesai (7 Okt 2026, audit dokumen ↔ kode)

- Widget bertingkat (7 Okt malam): `WidgetSync` hanya memantau `accounts`/`transactions`/`exchange_rates`/`app_settings`, padahal baris tingkat besar membaca budget, kategori, goal dan recurring → jadwal/budget baru baru muncul di widget setelah app di-resume atau update 30 menit. Kini tabel-tabel itu ikut dipantau. Regresi `test/core/widget/widget_background_test.dart`; dicek di Xiaomi 14T.
- Widget (permintaan owner): tampilan lama hanya teks 4×1 dengan latar biru gelap dan tidak mirip Home; update sistem dijalankan dari `onUpdate` broadcast receiver lewat engine ter-cache, sehingga proses bisa dimatikan sebelum Dart merender (widget tertahan di "Memuat…"/angka lama). Kini 4×2 seperti kartu Total Balance (jumlah + garis saldo bulan ini, merah bila negatif, terang/gelap), update sistem lewat `WidgetRefreshWorker` (WorkManager) yang menunggu `done` lalu menghancurkan engine, tombol "Widget layar utama". Test `test/core/widget/widget_background_test.dart` (path grafik), `test/reports/report_data_test.dart` (`monthBalancePath`).
- Impor mutasi dengan ≥2 akun aktif: `StatementImportEntryScreen` memanggil `_pickFile(accounts.single)` / `_pickPdf(accounts.single)` → `StateError: Too many elements`, dropdown akun diabaikan. Kini akun pilihan dropdown menjadi target; tombol nonaktif sampai akun dipilih. Regresi `test/statement_import/import_screen_test.dart`.
- Kurs `16.250` (titik ribuan) tersimpan 16,25 di Kurs Mata Uang dan form akun (parser mengganti ',' → '.' lalu `double.parse`). `parseRate`/`formatRateInput` di `money.dart`; test `test/core/money_format_test.dart`.
- Chip Akun di Home memformat saldo non-IDR sebagai rupiah (`AmountText` tanpa `currency`). Available to Spend tidak ikut disembunyikan tombol mata → kini disembunyikan.
- Font 200%: label navbar overflow 32 px di bar 56 dp; label "Available to Spend" terpotong per huruf. Label navbar dibatasi 1,3× + FittedBox; ATS dan baris kurs menumpuk nominal di bawah label.
- Teks UI backup folder/auto-confirm/Bantuan hanya menyebut "saat aplikasi dibuka" padahal WorkManager juga menjalankannya → diperbarui.
- Route `/settings` tidak punya pintu masuk → dihapus.

## Selesai (7 Okt 2026, lanjutan)

- Uji emulator (multi-currency): form akun tidak mengisi kurs saat mata uang diganti (USD tampil kosong walau kurs default 16250 ada), dan saat berpindah USD → EUR kurs USD tetap di kolom lalu ikut disimpan sebagai kurs EUR. `AccountFormScreen._setCurrency` kini mengosongkan kolom dan memuat kurs tersimpan mata uang baru (abaikan hasil bila pengguna sudah berganti lagi). Regresi `test/features/accounts/account_form_kurs_test.dart`.
- Uji emulator: jam hasil OCR "08: 02" (spasi setelah titik dua) masuk ke deskripsi → `_time` di `statement_text.dart` menerima spasi setelah ':'; regresi di `scanned_statement_ocr_test.dart`.
- OCR PDF mutasi hasil scan (Android): `scanned_statement_ocr.dart`; ≤30 halaman, progress + Batal, file gambar sementara selalu dihapus. Test `test/statement_import/scanned_statement_ocr_test.dart` (8).
- WorkManager: `BackgroundSyncWorker.kt` + `backgroundSyncMain`. Dua race diperbaiki di `recurring_engine.dart`: baca aturan di luar transaksi (instance jadwal lama bisa terposting dua kali bila aturan diedit bersamaan) dan hapus instance hanya berdasar id (instance yang baru di-auto-confirm job bisa dihapus lalu periode yang sama diposting lagi). Test `test/recurring/recurring_concurrency_test.dart`.
- `PRAGMA busy_timeout` tidak menunggu saat VM profiler aktif (debug/test) → diganti busy handler Dart `waitWhenBusy`.
- SQLCipher + perlindungan jendela kehilangan kunci (flutter_secure_storage memakai `SharedPreferences.apply()`): plaintext migrasi disimpan sebagai `.plain-pending` + penanda `.key-unconfirmed` (pid) sampai proses berikutnya membaca balik kunci; kunci yang hilang sebelum tersimpan → migrasi diulang dari plaintext atau DB baru dibuat dan file lama dipindah (`.unreadable-<waktu>`). Test `test/core/database_cipher_test.dart` (12).
- Entrypoint widget headless tidak ditemukan (bukan di `main.dart`) → `WidgetCompute.kt` memakai URI library.
- Salinan backup folder tidak lagi bisa setengah jadi dengan nama final (`.partial` → rename). Restore `.finbro` dengan passphrase di perangkat tanpa kunci backup kini menyimpan kunci itu.

## Selesai (7 Okt 2026)

### FAB (+) Home tertutup navbar
- Penyebab: FAB Scaffold cabang diposisikan 16 dp dari bawah layar (di belakang navbar); `Transform.translate(-58)` kurang dari tinggi navbar (68 + gap 16 + inset sistem), jadi ±10 dp bagian bawah FAB tertutup dan tap jatuh ke navbar; FAB Transaksi tidak diangkat sama sekali. `navBarClearance` juga menghitung tinggi navbar dua kali.
- Perbaikan: `AppShell` menerbitkan tinggi penuh navbar (`_NavBarScope`, satu nilai inset untuk bar dan FAB); `AboveNavBar` dipakai FAB Home dan Transaksi; `navBarClearance` = tinggi navbar + 16 (atau + 96 dengan FAB).
- Test: `test/app/shell_fab_test.dart` (router asli, inset 0 dan 34 dp: FAB di atas navbar, tap di tepi bawah FAB mengenai FAB, baris terakhir Home tidak tertutup FAB).

### Widget dimatangkan
- Engine headless tidak punya handler `render` → snapshot Dart tidak pernah sampai ke widget. `WidgetCompute` kini mendaftarkan `WidgetChannel` pada engine tersebut.
- `WidgetSync` (`lib/core/widget/widget_service.dart`) menggantikan `widgetRefresherProvider`: menghitung di koneksi app sendiri setelah tulis ke `accounts`/`transactions`/`exchange_rates`/`app_settings` (coalesce 300 ms, snapshot sama tidak dikirim ulang) dan saat start/resume (lifecycle task). Sebelumnya hanya commit ledger + panggilan manual, sehingga saldo awal akun, kurs, restore, onboarding, demo data tidak memperbarui widget.
- Caption bertanggal ("Diperbarui 3 Okt 09:05"); mask sembunyikan saldo = "Saldo disembunyikan", PIN = "Terkunci"; sebelum onboarding/DB belum ada → "Rp –" + "Buka FinBro untuk mulai" tanpa membuat DB; tap membuka app sejak sebelum snapshot pertama; ukuran 4×1 sesuai dokumen; deskripsi di pemilih widget.
- Test: `test/core/widget/widget_background_test.dart` (mask, tanggal, baris masa depan, sync setelah perubahan, tanpa kirim ulang yang tidak berubah).

### Klaim dokumen yang belum ada di kode
- Backup terenkripsi ke folder: UI di Backup & Restore + restore `.finbro`; format v2 ter-chunk, enkripsi/dekripsi streaming file-ke-file di isolate (dulu `package.readBytes()` penuh). Test `test/backup/{encrypted_backup,folder_backup_service}_test.dart`.
- `validateFile` dulu membaca tiap entri penuh ke memori di isolate UI → kini streaming per chunk 1 MB di `Isolate.run`; `buildPackage` juga di isolate.
- Multi-currency: input/tampilan nominal transaksi, recurring, scan, PDF, CSV mengikuti mata uang akun; total harian/top expense/filter nominal dalam rupiah.
- Hapus semua data (debug) kini mereset kurs; pesan PDF hasil-scan tidak lagi menyiratkan bisa dibaca di Android.

## Selesai (3 Okt 2026)

### Multi-currency (roadmap)
- Skema v5: tabel `exchange_rates` (kurs manual rupiah per unit, CHECK > 0) + enum `Currency` (11 kode). Migrasi v4→v5 menambah tabel + seed kurs default; instalasi baru seed sama di `seedDefaults`.
- Model konversi: amount tersimpan minor unit (IDR/JPY satuan; lainnya sen). Konversi SQL `ROUND(amount × rate_to_idr ÷ 10^decimals)` per baris lewat subselect kurs akun masing-masing. IDR→IDR identik dengan perilaku lama.
- `FinanceService`: semua agregat lintas akun (total balance, summary, ATS, dana darurat, net saved, trend, spending by category, budget aktual, upcoming obligations) dikonversi ke IDR; `AccountBalance.idrBalance` untuk tampilan per akun.
- `LedgerService`: transfer lintas mata uang ditolak dengan pesan jelas.
- UI: form akun pilih mata uang + kurs (+ preview ≈Rp), daftar/detail akun tampil native + ≈Rp, editor kurs di Pengaturan → Kurs Mata Uang, `MoneyField`/`formatMoney`/`parseMoney` per desimal mata uang.
- Test: `test/core/currency_migration_test.dart`, `test/core/finance_currency_test.dart`, `test/core/money_format_test.dart`, `test/features/accounts/account_currency_test.dart`.

### Widget home screen (roadmap)
- Widget 4×1 Android: `FinBroWidgetProvider.kt` (RemoteViews), `WidgetCompute.kt` (headless Flutter engine ter-cache, entrypoint `widgetBackgroundMain`), channel `id.finbro.app/widget`. (Alur refresh diperbaiki 7 Okt, lihat di atas.)
- Snapshot dihitung Dart murni dari DB (unit-testable di Linux): total balance dari `FinanceService.totalBalance`; mask `••••••` bila PIN aktif ATAU toggle sembunyikan saldo aktif — Kotlin tidak pernah menampilkan angka yang tidak dikirim Dart.
- Test: `test/core/widget/widget_background_test.dart`.

### Impor statement PDF (roadmap)
- Ekstraksi text-layer dengan pdfrx (PDFium native di isolate-nya sendiri; komposisi baris via `Isolate.run`): parser baris statement (`parseStatementLines`) membaca layout BCA/Mandiri (timestamp, MUTASI DEBET/KREDIT/SALDO, deskripsi terpotong); furniture halaman difilter.
- PDF terenkripsi: dialog kata sandi hingga 3 percobaan, batal aman; PDF hasil-scan (tanpa text layer) awalnya ditolak — OCR-nya selesai 7 Okt (lihat di atas).
- Review/commit/duplikat berbagi alur CSV (`/import`). Test: `test/statement_import/pdf_statement_test.dart`.

### Backup/restore streaming (batas memori dihapus)
- `buildPackage` menulis zip langsung ke file (`_StreamingZipWriter`, STORE, CRC streaming); tidak lagi memuat seluruh zip ke memori. (Enkripsi folder dari file dan isolate menyusul 7 Okt.)
- `BackupService.validateFile(File)` menggantikan validasi byte: staging per entri ke direktori sementara, cek nama aman, batas entry/total, CRC per entri, checksum SHA-256 dari manifest. `ValidatedBackup` kini file-backed (`sqliteFile`, `files`, `ownedDirectory`) dengan `dispose()`.
- Restore UI/flow memakai `restoreFromFile` (file picker langsung ke file), dispose di semua jalur (batal, gagal, selesai). (`restoreFromBytes` dihapus 7 Okt; tidak punya pemanggil.)
- Instalasi backup: `installBackup` menerima `ValidatedBackup` file-backed; lampiran disalin per file.
- Paket backup berada di direktori kerja aplikasi; gagal build tidak meninggalkan file; `dispose()` menghapus paket sementara.
- Pubspec menambah `convert` (sink hash streaming).
- Test: seluruh `test/backup` dimigrasi ke API file (writeZip → validateFile; ValidatedBackup file-backed; tamper CRC via patch byte zip langsung). Suite penuh 259 lulus, `flutter analyze` bersih.

### Hash PIN terikat Android Keystore (audit long-term)
- `PinVerifierChannel.kt`: HMAC-SHA256 dengan kunci non-ekspor di AndroidKeyStore (`finbro.app_lock.pin_binding.v1`), perbandingan constant-time; kegagalan Keystore eksplisit (`PinIntegrityException`), tidak pernah downgrade ke verifier database saja.
- Dart: `setPin`/`verifyPin`/`changePin`/`disable` melewati binding; hash legacy tanpa binding dimigrasi otomatis setelah PIN benar. PIN hash/salt tidak ikut backup (LOCK-003).
- Test: `pin_hash_test.dart` — binding tersimpan, verifikasi gagal eksplisit bila binding tidak cocok, cooldown tetap bekerja.

## Selesai (2 Okt 2026)

### Impor mutasi bank CSV (sesi terbaru; jangan dikerjakan ulang)
- Parser preset 7 bank (BCA, Mandiri, BNI, BRI, Jago, SeaBank, blu) + deteksi header/tanggal/amount, mapping manual bila tidak yakin (`csv_statement_parser.dart`, sudah ada sebelumnya) kini terhubung ke UI.
- Layar tinjau `/import` (menu Lainnya → Impor Mutasi Bank): pilih akun → pilih file CSV (lock-exempt, batas 20 MB) → tinjau per baris (include/exclude, kategori per baris, badge duplikat) → impor.
- Duplikat dicocokkan ke transaksi existing (akun sama, jumlah sama, tanggal ±2 hari, kesamaan deskripsi); baris diimpor sebagai `confirmed` dengan `sourceType: statement_import`; baris yang gagal validasi dilewati dan dihitung.
- Test: `test/statement_import/import_service_test.dart` (4) + `import_screen_test.dart` (2). Suite penuh 253 lulus.

### Uang / ledger
- [P1] Hapus transaksi auto-confirm recurring → instance ditutup `skipped`, tidak terposting ulang (+test).
- [P2] Edit jadwal rule tidak membuat instance kedua di periode settled; start date lampau tidak backfill/auto-post; perubahan rule diserialisasi; confirm/close atomik.
- [P2] `developmentAllocation` tidak menghitung `adjustment` (+test).
- [P2] `accountBalances` mengabaikan transaksi bertanggal setelah sekarang (+test).
- [P2] Form transaksi: lampiran yang sedang di-link tidak terhapus saat layar ditutup; `PopScope` selama menyimpan; image picker lewat `runExempt`.
- [P2, keputusan owner] Net Amount Saved = transfer bersih ke account Savings saja. Kontribusi goal = progres goal, tidak dihitung tabungan (+test).
- [P3] Threshold budget integer; `averageEssentialMonthly` dibagi bulan yang benar-benar punya riwayat, guard 0 (+test); batas atas budget per hari kalender, bukan 24 jam (+test); kategori nonaktif ditolak; `duplicate()` mempertahankan draft.

### Platform / stabilitas
- Safety snapshot tidak menimpa; salt+hash PIN satu transaksi; limiter PIN persisten bertingkat.
- Onboarding menjadwalkan daily check; reminder lama dibatalkan setelah restore; `root.dart` membuka ulang DB jika `close()` gagal; handler notifikasi background menangkap error; `LogScreen`/`BackupScreen` cek `mounted`, error CSV/baca/hapus backup ditangani.
- Zip encode/validate/sha256 berjalan di `Isolate.run` (validate per entri streaming sejak 7 Okt).

### Performa
- `dbChangesProvider` per tabel + coalesce 32 ms; tidak ada tulisan no-op saat resume.
- Daily check, monthly review dan reminder recurring hanya dijadwalkan ulang bila berubah (diff terhadap pending).
- Home: saldo dan ringkasan bulan dihitung sekali; `budgetUsages` 2 query (bukan N+1); `monthlyTrend` 1 query.
- `runApp` tidak menunggu init notifikasi; `app.dart` hanya watch setting yang dipakai.
- Daftar transaksi (Transaksi dan detail account): keyset pagination `(transactionAt, createdAt, rowid)`, bukan re-query dari offset 0 (+test).
