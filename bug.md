# FinBro — Bug & Stability Backlog

Sumber: audit read-only 4 agen (Ledger, Platform, Perf, Security) pada 2 Okt 2026.
Status dicek dari kode di disk. Tiga agen perbaikan (LedgerFix, PlatformFix, SecurityFix) **berhenti di tengah jalan karena rate limit (429)**, jadi pekerjaan mereka parsial.

## 0. Status build (DIPERBARUI)

Blocker analyze sudah diperbaiki: `flutter analyze` hanya menyisakan 1 warning (`app_logger.dart:5` memakai `package:drift/remote.dart`), dan `flutter test` **190 test lulus**. Test lama `auto-confirm...` diubah karena perilaku backfill-auto-post memang bug (lihat audit); ditambah test baru untuk start date lampau.

Catatan: sebagian item PlatformFix/LedgerFix ternyata sudah masuk ke kode sebelum agen berhenti (dbChanges scoping + debounce + test, threshold integer, auto-confirm tidak backfill, scan/picker). Verifikasi sisanya lewat `git diff` sebelum menganggap belum dikerjakan.

- `lib/core/finance/finance_service.dart:63` — `budgetStatus(usage)` → `budgetStatus(actual, budget)`
- `lib/features/budgets/domain/budget_alert_service.dart:54, 134` — `crossedThreshold` (3 arg) dan `budgetStatus`
- `lib/features/budgets/presentation/budget_screen.dart:142` — `budgetStatus(used, total)`
- Warning: `app_logger.dart:5` memakai `package:drift/remote.dart` (eksperimental) — ganti/cek ulang.

Setelah itu: `flutter analyze` + `flutter test` penuh.

## 1. Sudah selesai (terverifikasi laporan agen, tests lokal lulus)

| Slice | Item |
|---|---|
| ScannerFix | picker dibungkus `AppLockGate.runExempt` + maxWidth/Height 4000; CropView error state; decode crop tidak full-res; preview `cacheWidth`; hash gambar sekali di isolate; tanggal OCR di luar [2000, now+365] dibuang (+test) |
| DbIndexFix | 11 index (schema v2, migrasi v1→v2, test migrasi), `PRAGMA busy_timeout=5000` |

## 2. Belum selesai / perlu diverifikasi ulang (parsial dari agen yang gagal)

Periksa `git diff` tiap file; anggap belum selesai kecuali terbukti.

### Ledger / uang (prioritas tinggi)
- [P1] Hapus transaksi auto-confirm recurring → terposting ulang saat sync. Fix: tutup instance sebagai `skipped` jika rule `autoConfirm`. `ledger_service.dart:203`
- [P2] Edit jadwal rule membuat instance kedua di periode yang sudah settled / menghilangkan kewajiban periode ini. `recurring_engine.dart:253`
- [P2] Start date lampau mem-backfill semua kejadian dan auto-post (daily sejak 2000 ≈ 9,7 rb baris). Generate dari awal periode berjalan; jangan auto-confirm due < createdAt. `recurring_engine.dart:250`
- [P2] `regenerateRule`/`setActive`/`delete` tidak diserialisasi lewat `_tail`; skip/cancel race dengan confirm; create+close tidak atomik. `recurring_engine.dart:121,207,215`
- [P2] `developmentAllocation` ikut menghitung `adjustment` (netSaved tidak). `finance_service.dart:297`
- [P2] `accountBalances` menyertakan transaksi future-dated → rekonsiliasi & Home miring. `finance_service.dart:161`
- [P2] Keluar form saat save menghapus file lampiran yang akan di-link (`dispose` + `_pending`); tambah `PopScope` saat `_saving`. `transaction_form_screen.dart:108`
- [P2, butuh keputusan owner] `netSaved` double-count kontribusi goal + transfer ke akun Savings (`transactionId` movement tak pernah di-set). `finance_service.dart:332`
- [P3] Threshold budget memakai double (57000/100000*100 = 56.999…) → bandingkan integer. (sedang dikerjakan — lihat blocker)
- [P3] `averageEssentialMonthly` dibagi lookback penuh & tanpa guard 0 (NaN → `round()` throw). `finance_service.dart:311`
- [P3] Batas atas `budgetActual` pakai `Duration(days:1)` (salah di zona DST); pakai `nextMonthStart`. `finance_service.dart:450`
- [P3] `_validate` menerima kategori nonaktif; `duplicate()` menjadikan draft → confirmed. `ledger_service.dart:227`
- Form transaksi: `ImagePicker().pickImage` (~baris 173) belum dibungkus `runExempt`.

### Platform / stabilitas
- [P1] Safety snapshot restore bisa menimpa snapshot sebelumnya (nama per menit) → data asli hilang. Tambah detik + suffix unik. `backup_service.dart:83`
- [P2] Salt & hash PIN ditulis terpisah → bisa lockout permanen. Satu `db.transaction`. `app_lock_service.dart:66`
- [P2] Limiter PIN hanya di memori (kill app = reset). Persist + cooldown bertingkat. `app_lock_service.dart:156`
- [P2] Onboarding `_finish` tidak me-reschedule daily check. `onboarding_screen.dart:151`
- [P2] Reminder recurring DB lama tidak dibatalkan setelah restore. `recurring_engine.dart:297`
- [P3] Zip encode/validate/sha256 di UI isolate (ANR untuk backup besar). `restore_flow.dart:51`, `backup_service.dart:141`
- [P3] Handler background notifikasi: error tak ditangani (busy_timeout sudah ditambah). `notification_service.dart:266`
- [P3] `FinBroRoot._replace`: jika `close()` melempar, app stuck di layar hitam. `root.dart:49`
- [P3] `BackupScreen`: `ref` dipakai setelah await tanpa `mounted`; CSV/delete tanpa try/catch. `backup_screen.dart:62`
- [P3] `LogScreen._checkNow` tanpa `mounted`. `log_screen.dart:59`

### Performa
- [P1] `dbChangesProvider` memakai `tableUpdates()` global → setiap tulis (termasuk `app_settings`) recompute seluruh Home. Scope per tabel + debounce 16–50 ms. `providers.dart:12` *(PlatformFix sempat mengerjakan; belum terverifikasi)*
- [P1] Tulis no-op tiap resume: `clean_shutdown`, batch recurring (Batch selalu notify), upsert `daily_activity`. `startup_checks.dart:34`
- [P1] Reschedule semua notifikasi tiap resume (~100 panggilan plugin). Diff terhadap pending. `daily_check_service.dart:117`
- [P2] `homeOverviewProvider` menghitung `accountBalances` dua kali; `budgetUsages` N+1; `monthlyTrend` banyak query. `dashboard_providers.dart:34`
- [P2] `runApp` menunggu init timezone/notifikasi. `main.dart:13`
- [P2] `app.dart` watch seluruh map settings → rebuild MaterialApp tiap tulis settings. `app.dart:24`
- [P3] "Load more" transaksi re-query dari offset 0 (O(k²)); pakai keyset pagination. `activity_screen.dart:222`

## 3. Belum divalidasi (dari STATUS.md)
OCR struk foto asli, TalkBack, sidik jari, notifikasi di Doze dalam/OEM lain.
