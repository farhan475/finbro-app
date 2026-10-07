# FinBro Implementation Summary

Date: 7 Oktober 2026 · Version 1.0.0+1 · Application ID `id.finbro.app`
Verified: `flutter analyze` clean. Full suite: **360 tests passing** (7 Okt 2026, after the docs ↔ code audit). Emulator (Pixel 8 Pro, Android 17) checks passed for the features changed 2–7 Okt; a physical-device release check is still pending; see `STATUS.md`.

Spec: planning pack in `~/Downloads/finebro app/`. Details and decisions: `README.md`. Release readiness and open work: `STATUS.md`.

## Implemented (all planning-pack MVP phases 0–6)

- Foundation: Flutter, Drift SQLite (schema v5; frozen dumps v1–v5 in `drift_schemas/` — v2 query indexes, v3 goal link, v4 attachment sha256, v5 exchange_rates — with stepwise migrations; migration tests in `test/core/schema_migration_test.dart`), Riverpod, go_router, light/dark theme from the UI reference (`~/Downloads/finebro app/FinBro_Contoh_UI.png`): monochrome surfaces + lime accent `#5BEB12`, Inter font, monochrome logo/icon.
- Navigation: bottom bar Home | Transaksi | Budget | Analitik (Laporan) | Lainnya; Tujuan Keuangan opens from Lainnya and the Home goals card.
- Data: accounts, categories (seeded), transactions, attachments, budgets, goals (optionally linked to a Savings account, schema v3) + goal_movements, recurring rules/instances, daily_activity, planning_settings, app_settings, merchant_mappings, exchange_rates.
- Logic: ledger as the single write path; balances (confirmed rows dated up to now), available-to-spend, emergency fund, savings rate (net transfers into Savings accounts), budget usage, upcoming obligations (`lib/core/finance`).
- Features: account/category CRUD (archived accounts reject new postings), income/expense/transfer, filter/search, edit/delete/duplicate, account reconciliation, budgets with 70/85/100% (per-budget editable) and over-budget alerts, goals, recurring (weekly/monthly/yearly/custom interval, H/H-1/H-3 reminders, salary preset) with confirm/skip/auto-confirm, calendar, planning settings, onboarding, empty states, demo data + full wipe (debug).
- Reports: monthly and yearly scope — income vs expense, spending donut, top spending, budget vs actual, metrics panel (N/A on zero denominators), PDF report export (monthly or yearly). Transaction CSV export (with `currency` column) lives in Backup & Restore.
- Notifications (`flutter_local_notifications`, exact scheduling with inexact fallback when permission is unavailable, boot receiver): daily check with actions, budget thresholds, recurring/salary reminders, monthly review.
- Scan: ML Kit on-device OCR (camera, receipt from gallery, screenshot from gallery), preprocessing, crop step, receipt + screenshot parsers, confidence, merchant mapping, duplicate detection, draft review.
- Statement import: bank CSV from BCA, Mandiri, BNI, BRI, Jago, SeaBank, blu (parser presets + manual column mapping), entry via Lainnya → Impor Mutasi Bank (`/import`), review screen with per-row include/exclude + category, duplicate warning against existing transactions, rows post as confirmed with source `statement_import` (`lib/features/statement_import`, tests in `test/statement_import/`). PDF statements: text-layer extraction with pdfrx (password dialog, 3 attempts); scanned-only PDFs are read with on-device OCR on Android (max 30 pages).
- Multi-currency: accounts in 11 currencies (`Currency` enum), manual kurs per currency (`exchange_rates`, schema v5) editable in Pengaturan → Kurs Mata Uang; amounts stored as integer minor units and entered/shown in the account's currency (transaction, recurring and scan forms, lists, detail, PDF, CSV); all cross-account figures (total balance, ATS, emergency, savings rate, budgets, goals, day totals, top expenses, amount filter, reports) converted to rupiah; per-account screens show native amount + ≈Rp; transfers only between accounts of the same currency. (`lib/core/formatting/money.dart`, `FinanceService.idrSql`, `lib/features/settings/presentation/exchange_rates_screen.dart`.)
- Home-screen widget: Android 4×2 widget styled like the Home balance card — "Total Balance", the amount, "Diperbarui <tanggal> <jam>" and the month's balance line (`FinBroWidgetProvider.kt`, chart bitmap from `WidgetChart.kt`, points from `FinanceService.monthBalancePath`, the same path as the Home sparkline); resized taller it adds the change line and Income | Expense, then Available to Spend, the highest-usage budget and the next schedule, and each section opens its screen (Home, Analitik, Budget, Transaksi Berulang); masked `Rp ••••••` + `Terkunci` whenever the app lock PIN is set, `Saldo disembunyikan` with the Home eye toggle (no chart or details while masked); negative total in red; light/dark from the system. While the app runs `WidgetSync` re-renders after writes to accounts/transactions/kurs/settings/budgets/categories/goals/recurring and on start/resume; placement and the 30-min system update queue `WidgetRefreshWorker` (headless engine `widgetBackgroundMain`, destroyed after `done`). Lainnya → Pengaturan → "Widget layar utama" pins it from the app.
- Security/reliability: PIN + biometric app lock (persistent escalating limiter, monotonic relock, FLAG_SECURE in release builds, PIN hash bound to a non-exportable Android Keystore HMAC key with automatic legacy migration), ZIP backup/restore fully streaming/file-backed in background isolates with manifest + DB & per-attachment SHA-256 + per-entry CRC32 verification, schema/trigger/size validation and safety snapshot, encrypted `.finbro` backups (AES-256-GCM chunked, Argon2id passphrase) to a user-chosen SAF folder on a daily/weekly schedule with retention 3–30 plus encrypted restore, integrity check (incl. missing/orphan attachments and post-restore checksum mismatches), local error log, backup reminder banner (>30 days or never) on Home and Lainnya. No network permissions in release.
- Release: signed AAB/APKs (keystore in `~/finbro-keys/`), `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`, CI (`.github/workflows/ci.yml`).

## UI follow-up

- Floating navbar uses a frosted glass surface. Active destination highlights icon and label with the accent only; no selected pill background.
- Branch FABs (Home, Transaksi) use `AboveNavBar`, which lifts them by the bar's full height published by the shell (`_NavBarScope`: bar + gap + system inset). The earlier `Transform.translate(-58)` left the Home FAB ~10 dp behind the bar (more with a 3-button/gesture inset); fixed 7 Okt with regression test `test/app/shell_fab_test.dart`. List padding uses `navBarClearance` from the same value. Needs an on-device visual check; see `STATUS.md`.
- Large font scale: navbar labels are capped at 1.3× and shrink to fit (at 200% they overflowed the fixed 56 dp bar); Home Available to Spend and the kurs rows stack the amount under the label instead of squeezing it.

## Change log 7 Oktober 2026 (audit dokumen ↔ kode, UI Pengaturan/kurs)

- Widget redesigned and made reliable (owner request): 4×2 card like the Home "Total Balance" card with the month's balance line (Kotlin bitmap, monotone curve + fill + dots), negative total in red, light/dark colors from FinColors. System updates now run as WorkManager work (`WidgetRefreshWorker`) instead of a cached engine started from the broadcast receiver, whose process could die before Dart rendered. New "Widget layar utama" tile (pin request) and a Bantuan entry. Home sparkline and widget share `FinanceService.monthBalancePath` (replaces `homeCashFlowProvider` + `balancePath`).
- Fixed: Impor Mutasi Bank with 2+ active accounts — both file buttons called `accounts.single` (StateError, nothing opened) and ignored the dropdown. The chosen account is now the target; the buttons stay disabled until one is picked. Regression in `test/statement_import/import_screen_test.dart`.
- Fixed: kurs typed as `16.250` (Indonesian thousands separator) was stored as 16,25. Kurs fields (Pengaturan → Kurs Mata Uang, account form) use `parseRate`/`formatRateInput` (`money.dart`): '.' groups thousands, ',' is the decimal mark; fields show `16.250`. Tests in `test/core/money_format_test.dart`.
- Fixed: Home "Akun" chips showed non-IDR balances as rupiah (`$100,00` rendered `Rp 10.000`); they now use the account currency. Available to Spend is masked by the Home eye toggle as well.
- Kurs Mata Uang screen redesigned: info card, one row per currency (symbol badge, code, name, "Diubah <tanggal>", right-aligned rupiah field), save button pinned at the bottom; only changed rates are written, so the date shows the real last edit.
- Account form: currency is a dropdown placed before the kurs and opening balance; the ≈Rp preview follows both fields live.
- Notifikasi: page padding aligned with other settings pages; exact-alarm permission button moved under its explanation (the title no longer wraps). Log aplikasi: "Periksa sekarang" is a proper button.
- UI text: folder backup, auto-confirm recurring and Bantuan now say the work also runs in the background (~6 h), not only when the app opens.
- Removed the unreachable `/settings` route (`SettingsScreen`); settings live in Lainnya → Pengaturan. `AppearanceScreen` moved to `appearance_screen.dart`.

## Change log 7 Oktober 2026 (lanjutan: fitur yang ditunda)

- Scanned PDF statements: OCR on Android (pdfrx renders each page, ML Kit reads it, same statement line parser and review flow; max 30 pages, progress + cancel; review flagged "PDF scan (OCR)"). `lib/features/statement_import/domain/scanned_statement_ocr.dart`, tests `test/statement_import/scanned_statement_ocr_test.dart`.
- Background work: WorkManager `BackgroundSyncWorker.kt` (periodic 6 h, battery-not-low, skipped while the app is on screen) runs `backgroundSyncMain` → recurring sync incl. auto-confirm with budget alerts, daily-check reschedule, widget render, due folder backup. Recurring generation made safe for two connections; tests `test/recurring/recurring_concurrency_test.dart`, `test/background/external_writes_test.dart`.
- SQLCipher: live database encrypted (random 256-bit key in flutter_secure_storage); plaintext installs migrated on first open with a verified copy and the plaintext kept until a later process confirms the key; backups stay plaintext and are re-encrypted on restore; error screen offers "Mulai dengan database baru" (old file kept) when the key is gone. Tests `test/core/database_cipher_test.dart`, `test/backup/backup_service_test.dart`.
- Folder backups are copied under `.partial` and renamed when complete; leftovers are cleaned. `.finbro` restore on a device without a backup key adopts the backup's key.
- Widget headless entrypoint is now resolved by library URI (`package:finbro_app/core/widget/widget_background.dart`); before, the engine could not find `widgetBackgroundMain` outside `main.dart`.

## Change log 7 Oktober 2026

Docs ↔ code sync; everything the docs claimed is now in code.

- Fixed: Home/Transaksi add FAB hidden behind the navbar (see UI follow-up).
- Widget matured: the headless engine had no `render` handler, so Dart snapshots never reached the widget; refresh now follows all balance/kurs/lock/hide-balance/onboarding writes plus start/resume (was ledger commits only); dated caption; distinct hidden vs locked mask; no DB creation before first launch; 4×1 sizing, tap-to-open before the first snapshot, picker description.
- Encrypted folder backup UI + `.finbro` restore; format v2 chunked/streaming.
- Multi-currency completed for entry/display of account-bound amounts.
- Backup validation stages entries by streaming in an isolate; build also in an isolate; legacy byte APIs removed.
- Debug wipe also resets kurs to defaults; scanned-PDF message corrected (OCR for scanned PDFs followed later the same day).

## Change log 2 Oktober 2026

All open items from the 4-agent audit closed; details in `bug.md`, `audit.md`, `CHANGELOG.md`.

- Statement import (latest this session): bank CSV import wired end-to-end — route `/import` with entry in Lainnya, review screen (include/exclude, per-row category, duplicate badge, manual column mapping), commit through `LedgerService` with `sourceType: statement_import`, 6 tests (`test/statement_import/`). PDF statements followed on 3 Okt.

- Money: future-dated rows excluded from balances; Net Amount Saved = net transfers into Savings accounts only (owner decision); development allocation ignores goal adjustments; emergency average over months with history; budget end date = whole calendar day; auto-confirmed recurring delete stays deleted; form keeps attachments safe while saving.
- Security: relock on monotonic + wall clock with a 5-minute cap for pickers/dialogs; lock blocks focus and Back; restore validates `user_version`, tables, drops triggers/views; backup size limits, unknown entries rejected; CSV tab/CR neutralized.
- Performance: recurring reminders diffed; Home balance computed once; batched budget usage and trend queries; cursor pagination (`TransactionPager`) on Transaksi and account detail.
- CI signs release builds with a throwaway key.

## Change log 1 Oktober 2026

### UI revision to the reference (FinBro_Contoh_UI.png) — not yet checked on device

- Palette (`app_theme.dart` `FinColors`): light background `#F7F8FA`, surface `#FFFFFF`; dark background `#0B0D10`, surface `#12151A`; accent lime `#5BEB12` (replaced the first indigo pass; `accentText` for legible text on light surfaces, chart ramp derived from it); positive green, negative red, warning amber.
- Theme: pill-shaped chips and segmented buttons; the earlier bottom nav used a selected indicator, later replaced by the current icon/text-only accent state without a selected shape; progress bars use accent-tinted tracks.
- Bottom nav: Goals tab replaced by **Analitik** (Laporan as a tab); "More" renamed **Lainnya**; Tujuan Keuangan added to Lainnya. `/reports` is now a shell branch, `/goals` a top-level route; monthly-review notification uses `go`.
- Home (`home_screen.dart`): avatar with initial + bell (opens Transaksi Berulang, dot when items await confirmation); Total Balance card with eye toggle (`SettingKeys.hideBalance`), change vs start of month ("↑ x% dari bulan lalu"), accent sparkline of the balance path this month (`BalanceSparkline`, `balancePath`), Income/Expense split inside the card; Available to Spend as a compact row; account chips moved to an "Akun" section. Separate Cash Flow card removed (trend now in the balance card; full chart stays in Laporan).
- Charts: income line/bars in accent, curved income line with fading fill; budget-vs-actual "Actual" in accent.
- Budget list: solid primary icon tiles (`IconAvatar(filled: true)`).
- Kalender: today shown as a filled accent circle; markers tinted (recorded = amber dot, no activity = accent dash, unknown = ring; shapes still carry meaning).
- Tujuan Keuangan: Semua / Aktif / Selesai filter chips; colored round goal icons per type (`GoalIcon`); full-width "Tambah Tujuan" button.
- Financial Health: rows with accent icon tile, value, share % and progress bar (`HealthMetric.percent`); benchmark/source kept; summary moved to an insight card with lightbulb at the bottom.

### Earlier in this session

- **Fixed: OCR crashed in every release build.** R8 stripped ML Kit internals (`NullPointerException` in `mlkit_vision_common.zzmj.<init>` on every recognize call; debug builds unaffected). Added ML Kit keep rules in `android/app/proguard-rules.pro`. Verified on device: receipt → Rp 49.000 / 1 Okt 12:41 / Indomaret; GoPay screenshot → Rp 35.000 / Kopi Kenangan / "Terdeteksi: GoPay"; duplicate warning on re-scan.
- **Fixed: restore forgot backup history.** The restored DB carried its own old `last_backup_at` (none, since the backup is taken before that setting is written), so "Belum ada backup" reappeared right after a restore. `BackupService.restore` now keeps the newer of the live value and the backup date. Regression test in `backup_service_test.dart`.
- Added "Struk dari galeri" to Scan (FR-SCN-001 capture/import); before, receipts could only come from the camera.
- Large font scale (200%): segmented buttons used to break mid-word ("Expens/e") → new `SegmentLabel` in `fin_widgets.dart` used by every `SegmentedButton`. Home quick actions ("Tra…") and account-chip balances ("Rp 11.808.6…") now shrink instead of truncating; budget amount lines wrap; chart axis labels capped at 1.2× (they overlapped); More menu titles wrap to 2 lines.
- Frozen-schema/migration test `test/core/schema_migration_test.dart` + `test/generated_migrations/`.
- Backup reminder banner also on Home.
- Device test results (release build, Xiaomi 14T, Android 16): see STATUS.md → Verified.

## Known limits (by design)

- Single device, no sync/cloud yet (encrypted folder backup exists; offline-first sync is pending roadmap work). Backup is manual unless the user configures the encrypted folder backup.
- Exact reminders are supported when Android permission is allowed; otherwise scheduling falls back to inexact alarms. Delivery timing varies by device/Doze and needs validation.
- Live database encrypted with SQLCipher (per-device key); manual backup zips are plaintext for portability.
- Recurring processing runs on app open/resume and every ~6 h via WorkManager while the app is closed (OS may defer it under Doze/battery saver).
- Onboarding allocation steps by 5%; finer values in Settings → Planning.

## Build

```bash
flutter pub get
flutter test
ln -sf ~/finbro-keys/key.properties android/key.properties   # gitignored; remove after building
flutter build apk --release                 # universal APK
flutter build appbundle --release
rm android/key.properties
```

Without `android/key.properties` the release build fails with a `GradleException` (CI generates a throwaway key); it never signs with the debug key.

Signing: `~/finbro-keys/finbro-release.jks`, alias `finbro`. Back it up off this machine; losing it blocks all future updates.
