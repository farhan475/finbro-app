# FinBro — Finance Brother App

Personal finance app for Android, offline-first, single user. The spec is the planning pack in `~/Downloads/finebro app/` (PRD, functional requirements, formulas, schema, UX, OCR, notification, security, roadmap, test plan).

## Stack

| Area | Choice |
|---|---|
| UI | Flutter 3.47 / Dart 3.13, Material 3, monochrome surfaces + lime accent `#5BEB12` (light/dark), Inter font bundled offline |
| Database | SQLite via Drift (`lib/core/database`), schema v5 (frozen v1 baseline + query indexes, stepwise migrations); encrypted with SQLCipher 4 (`sqlite3` 3.x build hook `source: sqlcipher`, random 256-bit device key in `flutter_secure_storage`) |
| State | flutter_riverpod 3 (manual providers, no codegen) |
| Routing | go_router (bottom nav: Home, Transaksi, Budget, Analitik, Lainnya; Tujuan Keuangan from Lainnya/Home) |
| Charts | fl_chart; PDF reports via `pdf` |
| Notifications | flutter_local_notifications + timezone (local; exact Android scheduling with inexact fallback) |
| OCR | google_mlkit_text_recognition (on-device, Latin) — receipts, screenshots and scanned PDF statements |
| Statement import | CSV parser + `pdfrx` text-layer extraction for PDF statements; scanned PDFs rendered page by page with pdfrx and read by ML Kit (Android) |
| Background work | AndroidX WorkManager (`BackgroundSyncWorker.kt`, periodic 6 h) running the headless Dart entrypoint `backgroundSyncMain` |
| Backup | zip (archive, streaming file-backed writer/validator in a background isolate) + file_picker; optional encrypted `.finbro` backups (AES-256-GCM chunked, Argon2id via `cryptography`) to a user folder via SAF (`saf_util`/`saf_stream`, key in `flutter_secure_storage`) |
| App lock | PIN (salted, iterated SHA-256, bound to a non-exportable Android Keystore HMAC key) + local_auth biometrics |

Package id: `id.finbro.app`. Currency: accounts may hold IDR, USD, SGD, MYR, EUR, GBP, JPY, AUD, CHF, CNY or HKD, stored as integer minor units; every cross-account figure is reported in rupiah via the manual kurs (`exchange_rates`, schema v5).

## Structure

```text
lib/
├── app/            app.dart, root.dart (DB lifecycle/restore), router.dart, routes.dart, app_wiring.dart, theme/
├── core/
│   ├── database/   tables, enums, converters, seed, AppDatabase, database_cipher.dart (SQLCipher key + migration)
│   ├── background/ background_sync.dart (WorkManager headless entry) + external_writes.dart (refresh after other connections write)
│   ├── ledger/     LedgerService — the only write path for income/expense/transfer
│   ├── finance/    finance_math.dart (pure formulas) + FinanceService (read-side metrics)
│   ├── notifications/, settings/, storage/, formatting/, utilities/
│   └── widget/     widget_background.dart (snapshot + headless entrypoint) + widget_service.dart (WidgetSync)
├── features/       accounts, backup, budgets, calendar, categories, dashboard, goals, onboarding,
│                   planning, recurring, reports, scanner, security, settings, statement_import,
│                   transactions
└── shared/         lookup providers, common widgets
```

Cross-feature hooks live in `lib/app/app_wiring.dart`:
- Ledger listeners run after every commit: budget threshold alerts and daily-activity marking.
- Lifecycle tasks run on app start and every resume: pick up writes from other connections (`ExternalWrites`, via `PRAGMA data_version`), integrity check, recurring sync (instances, auto-confirm, reminders), daily-check/monthly-review scheduling, home-screen widget resync, and the automatic encrypted folder backup when due.
- Background tasks (`backgroundTasksProvider`) run from WorkManager every ~6 h while the app is not on screen: recurring sync, daily-check reschedule, widget render and the due folder backup, with the same ledger listeners as the app (budget alerts fire for background auto-confirms). Skipped before onboarding and when no database exists yet.

Every isolate (app, notification actions, widget, WorkManager) opens the live database only through `openDeviceDatabase()`. Two connections may write at once: recurring generation reads and inserts in one `BEGIN IMMEDIATE` transaction, posting closes the instance conditionally in the same transaction, and connections wait on each other with a Dart busy handler (`waitWhenBusy`).

The Android widget (`android/.../FinBroWidgetProvider.kt`) only displays what Dart sends over the `id.finbro.app/widget` channel (`render`). While the app runs, `WidgetSync` recomputes on the app's own DB connection after writes to `accounts`, `transactions`, `exchange_rates` or `app_settings` and on every start/resume. For system updates (widget placed, every 30 min via `updatePeriodMillis`) `WidgetCompute.kt` runs `widgetBackgroundMain` in a cached headless Flutter engine that reads the same SQLite file (never creates it).

## Run / build

```bash
flutter pub get
dart run build_runner build        # only after changing Drift tables
flutter test
flutter run -d <android-device>
flutter build apk --release                   # universal APK, signed with the release key
flutter build appbundle --release             # AAB for Play Store
```

### Release signing

- Keystore: `~/finbro-keys/finbro-release.jks` (alias `finbro`, RSA 4096, valid 10 000 days).
- Passwords: `android/key.properties` (git-ignored), copy in `~/finbro-keys/key.properties`.
- **Back up `~/finbro-keys/` somewhere safe.** Losing it means existing installs can never be updated.
- Without `android/key.properties` the release build fails (`GradleException`); it never falls back to the debug key.

On desktop (Linux) the app runs for development. OCR, the camera, and notification scheduling are Android-only there.

## Decisions agreed with the user (not written in the planning pack)

- Schema additions:
  - `accounts.icon`
  - `budgets.attention_threshold` (70), `warning_threshold` (85), `over_threshold` (100), editable per budget, and `budgets.last_notified_threshold`
  - `recurring_rules.interval_days`, `month_of_year`, `reminder_offset_days`, `reminder_time`
  - `attachments.image_hash`
  - `planning_settings.flexible_residual_mode` and `planning_settings.user_reserve`
  - new table `merchant_mappings`
  - `goals.linked_account_id` (v3), `attachments.file_sha256` (v4), table `exchange_rates` (v5)
- Net Income = total confirmed income.
- Goal contributions are `goal_movements`; the money stays in its accounts. `goals.current_amount` is a rebuildable cache. A goal linked to a Savings account (schema v3) takes that account's calculated balance (in rupiah) as its progress instead of movements.
- Emergency Fund balance = sum of active goals of type `emergency`.
- Reserved money = active goal balances + the rest of this month's Family allocation + the manual user reserve.
- Upcoming obligations = open recurring expenses due by the end of the current month.
- Savings Rate numerator (Net Amount Saved) = net transfers into savings-type accounts from non-savings accounts. Goal contributions are earmarks and count only as goal progress, never as saved money, so nothing is counted twice (owner decision, 2 Okt 2026; replaces the earlier goals + transfers rule).
- Account balances and Total Balance include confirmed transactions dated up to now; future-dated rows count from their date.
- Daily check = per-date local notifications scheduled 30 days ahead and cancelled once a day is ACTIVE or NO_ACTIVITY. "Ingatkan nanti" fires once, +1 hour.
- Budget alerts: attention 70%, warning 85%, over 100% and "melewati budget" (>100%), each at most once per period.
- Recurring instances and auto-confirm are processed when the app opens or resumes and, since 7 Okt 2026 (owner decision), every ~6 h by WorkManager while the app is closed (battery-not-low; skipped while the app is on screen).
- Database encryption (owner decision, 7 Okt 2026): SQLCipher with a random per-device key in Android Keystore-backed storage, never in backups. Existing plaintext databases are encrypted on first open (verified copy + atomic swap; the plaintext is kept as `finbro.sqlite.plain-pending` until a later app start reads the key back, because the key store persists asynchronously). Backups stay portable plaintext SQLite inside the zip and are re-encrypted with the device key on restore. A lost key is never answered by silently creating a new database: the user can set the unreadable file aside ("Mulai dengan database baru") and restore a backup.
- The UI mixes Bahasa Indonesia and English financial terms, as in the mockup. Colors follow the monochrome spec, not the violet swatches in the mockup.

## Roadmap status

- Seed merchant Indonesia: implemented with scan suggestions and tests.
- Exact notification scheduling: implemented on Android with permission check and inexact fallback; device delivery still needs validation.
- Multi-currency with manual rates: implemented (schema v5 `exchange_rates`, 11 currencies, minor-unit amounts; amounts are entered and shown in the account's own currency (transaction/recurring/scan forms, lists, detail, PDF, CSV `currency` column); every cross-account figure — totals, day-group totals, top expenses, amount filter, budgets, goals — is converted to IDR; kurs editor at `/settings/rates`; transfers only between accounts of the same currency).
- Android home-screen widget: implemented (4×1, Total Balance computed in Dart; `••••••` + `Terkunci` whenever the app-lock PIN is set, `Saldo disembunyikan` when the Home eye toggle hides balances; "Diperbarui <tanggal> <jam>" caption; resynced by `WidgetSync` after balance/kurs/lock/hide-balance writes and on app start/resume, and every 30 min by the headless engine).
- Bank CSV import: implemented (7 bank presets + manual mapping, review screen). PDF statements: implemented (pdfrx text-layer extraction, password support). Scanned (image-only) PDFs: OCR on Android (max 30 pages, page by page at ~216 dpi, progress + cancel, review flagged "PDF scan (OCR)"); off Android they are rejected.
- Encrypted folder backup via SAF: implemented (Backup & Restore → "Backup terenkripsi ke folder": folder, passphrase, harian/mingguan, keep 3/5/7/14/30, "Backup sekarang"; restore from `.finbro` with passphrase — a device without a backup key adopts the restored backup's key so automatic folder backups continue). Copies land under a `.partial` name and are renamed when complete, so an interrupted copy is never mistaken for a backup. Cloud sync using that format is not implemented.
- Backup/restore memory bound removed: zip write/validate/restore and `.finbro` encrypt/decrypt stream to and from files in background isolates (limits are size caps, not memory caps).

## Deviations / not done

- Cloud sync: not implemented (owner: not now; needs a sync design and an endpoint/provider).
- Statement PDFs that mix text pages and scanned pages use only the text layer.
- Manual backup zips and safety snapshots in app storage are plaintext SQLite (portable); only the live database and folder backups are encrypted.
- Flutter Web is not supported (Drift/SQLite via `dart:ffi`).

## Verified on device (Xiaomi 14T, Android 16 / HyperOS 3)

- Install, onboarding, transactions, budget, dashboard.
- Daily check notification at the chosen time, with actions; "Tidak ada" writes NO_ACTIVITY from the background isolate without opening the app.
- Budget alerts at 85% and 100%, no repeated alert for the same threshold.
- App lock: wrong PIN rejected with attempt counter, correct PIN and fingerprint unlock, relock on resume.
- Backup to Downloads via the system save dialog (manifest checksum matches), CSV export, restore preview from a picked file.
- Pending on device: navbar/FAB position fix (FAB lifted by the bar's full height, 7 Okt), home-screen widget, multi-currency entry/display, encrypted folder backup/restore, OCR accuracy on real photographed receipts.

## Implementation status (planning-pack TODO.md)

| Section | Status |
|---|---|
| Foundation: project, package name, app icon, monochrome logo, light/dark theme, migration layer, Drift + Riverpod | Done |
| Core Data: all tables incl. goals/movements, recurring rules/instances, daily activity, planning/app settings | Done |
| Core Features: account/category CRUD, income/expense/transfer, search/filter, edit/delete/duplicate, balance/budget/goal/ATS/emergency engines | Done |
| Notifications: local service, daily check, budget threshold, recurring, salary reminder, monthly review | Done (scheduling verified in code/tests; delivery needs a device) |
| Reports: income vs expense, spending donut, top spending bar, budget vs actual, savings rate, emergency coverage, metrics panel; monthly and yearly scope, PDF export for both | Done |
| OCR: device OCR (ML Kit), preprocessing, receipt + screenshot parsers, merchant mapping, confidence UI, duplicate detection | Done (accuracy spike on a target device pending) |
| Statement import: bank CSV (BCA/Mandiri/BNI/BRI/Jago/SeaBank/blu) and text-layer PDF, review screen with per-row category + include/exclude, duplicate detection, manual column mapping | Done (scanned-only PDFs rejected until OCR v2). Tests in `test/statement_import/` |
| Reliability: backup/export, restore/import, encrypted folder backup, integrity check, app lock, local error log | Done; device performance test pending |
| Release: seeded categories, onboarding, empty states, debug demo-data toggle + debug wipe, release keystore | Done; latest UI/widget changes still need a device check |
