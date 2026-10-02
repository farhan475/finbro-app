# FinBro Implementation Summary

Date: 2 Oktober 2026 · Version 1.0.0+1 · Application ID `id.finbro.app`
Verified: `flutter analyze` clean. Full suite: 253 tests passing (2 Okt 2026, includes 6 new statement-import tests). Device release UI is not verified; see `STATUS.md`.

Spec: planning pack in `~/Downloads/finebro app/`. Details and decisions: `README.md`. Release readiness and open work: `STATUS.md`.

## Implemented (all planning-pack MVP phases 0–6)

- Foundation: Flutter, Drift SQLite (schema v3 = frozen v1 baseline in `drift_schemas/` + query indexes and stepwise migrations; migration tests in `test/core/schema_migration_test.dart`), Riverpod, go_router, light/dark theme from the UI reference (`~/Downloads/finebro app/FinBro_Contoh_UI.png`): monochrome surfaces + lime accent `#5BEB12`, Inter font, monochrome logo/icon.
- Navigation: bottom bar Home | Transaksi | Budget | Analitik (Laporan) | Lainnya; Tujuan Keuangan opens from Lainnya and the Home goals card.
- Data: accounts, categories (seeded), transactions, attachments, budgets, goals + goal_movements, recurring rules/instances, daily_activity, planning_settings, app_settings, merchant_mappings.
- Logic: ledger as the single write path; balances (confirmed rows dated up to now), available-to-spend, emergency fund, savings rate (net transfers into Savings accounts), budget usage, upcoming obligations (`lib/core/finance`).
- Features: account/category CRUD (archived accounts reject new postings), income/expense/transfer, filter/search, edit/delete/duplicate, account reconciliation, budgets, goals, recurring (weekly/monthly/yearly/custom interval, H/H-1/H-3 reminders) with confirm/skip/auto-confirm, calendar, planning settings, onboarding, empty states, demo data (debug).
- Reports: income vs expense, spending donut, top spending, budget vs actual, metrics panel (N/A on zero denominators), CSV export, PDF monthly report export.
- Notifications (`flutter_local_notifications`, exact scheduling with inexact fallback when permission is unavailable, boot receiver): daily check with actions, budget thresholds, recurring/salary reminders, monthly review.
- Scan: ML Kit on-device OCR (camera, receipt from gallery, screenshot from gallery), preprocessing, crop step, receipt + screenshot parsers, confidence, merchant mapping, duplicate detection, draft review.
- Statement import: bank CSV from BCA, Mandiri, BNI, BRI, Jago, SeaBank, blu (parser presets + manual column mapping), entry via Lainnya → Impor Mutasi Bank (`/import`), review screen with per-row include/exclude + category, duplicate warning against existing transactions, rows post as confirmed with source `statement_import` (`lib/features/statement_import`, tests in `test/statement_import/`). PDF statements: not supported.
- Security/reliability: PIN + biometric app lock (persistent escalating limiter, monotonic relock, FLAG_SECURE), ZIP backup/restore with manifest + checksum, schema/trigger/size validation and safety snapshot, integrity check (incl. missing/orphan attachments), local error log, backup reminder banner (>30 days or never) on Home, Lainnya and Settings. No network permissions in release.
- Release: signed AAB/APKs (keystore in `~/finbro-keys/`), `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`, CI (`.github/workflows/ci.yml`).

## UI follow-up

- Floating navbar uses a frosted glass surface. Active destination highlights icon and label with the accent only; no selected pill background.
- Home add FAB was moved higher and the scroll clearance increased after the user reported it overlapped the navbar. The latest release UI still needs a successful on-device visual check; see `STATUS.md`.

## Change log 2 Oktober 2026

All open items from the 4-agent audit closed; details in `bug.md`, `audit.md`, `CHANGELOG.md`.

- Statement import (latest this session): bank CSV import wired end-to-end — route `/import` with entry in Lainnya, review screen (include/exclude, per-row category, duplicate badge, manual column mapping), commit through `LedgerService` with `sourceType: statement_import`, 6 tests (`test/statement_import/`). PDF statements remain out of scope.

- Money: future-dated rows excluded from balances; Net Amount Saved = net transfers into Savings accounts only (owner decision); development allocation ignores goal adjustments; emergency average over months with history; budget end date = whole calendar day; auto-confirmed recurring delete stays deleted; form keeps attachments safe while saving.
- Security: relock on monotonic + wall clock with a 5-minute cap for pickers/dialogs; lock blocks focus and Back; restore validates `user_version`, tables, drops triggers/views; backup size limits, unknown entries rejected, zip work off the UI isolate; CSV tab/CR neutralized.
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

- Single device, no sync/cloud yet (encrypted folder backup exists; offline-first sync is pending roadmap work). Backup is manual unless the user configures folder backups.
- Exact reminders are supported when Android permission is allowed; otherwise scheduling falls back to inexact alarms. Delivery timing varies by device/Doze and needs validation.
- No SQLCipher: OS storage protection plus app lock.
- Recurring processing runs on app open/resume; no background service.
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
