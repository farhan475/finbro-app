# FinBro Implementation Summary

Date: 1 Oktober 2026 · Version 1.0.0+1 · Application ID `id.finbro.app`
Verified: `flutter analyze` clean, `flutter test` 179 passing, signed release APK/AAB (R8) built and tested on Xiaomi 14T (Android 16) via adb.

Spec: planning pack in `~/Downloads/finebro app/`. Details and decisions: `README.md`. Release readiness and open work: `STATUS.md`.

## Implemented (all planning-pack MVP phases 0–6)

- Foundation: Flutter, Drift SQLite (schema v1, frozen in `drift_schemas/`, schema/migration test in `test/core/schema_migration_test.dart`), Riverpod, go_router, light/dark theme from the UI reference (`~/Downloads/finebro app/FinBro_Contoh_UI.png`): monochrome surfaces + indigo accent, Inter font, monochrome logo/icon.
- Navigation: bottom bar Home | Transaksi | Budget | Analitik (Laporan) | Lainnya; Tujuan Keuangan opens from Lainnya and the Home goals card.
- Data: accounts, categories (seeded), transactions, attachments, budgets, goals + goal_movements, recurring rules/instances, daily_activity, planning_settings, app_settings, merchant_mappings.
- Logic: ledger as the single write path; balances, available-to-spend, emergency fund, savings rate, budget usage, upcoming obligations (`lib/core/finance`).
- Features: account/category CRUD (archived accounts reject new postings), income/expense/transfer, filter/search, edit/delete/duplicate, account reconciliation, budgets, goals, recurring (weekly/monthly/yearly/custom interval, H/H-1/H-3 reminders) with confirm/skip/auto-confirm, calendar, planning settings, onboarding, empty states, demo data (debug).
- Reports: income vs expense, spending donut, top spending, budget vs actual, metrics panel (N/A on zero denominators), CSV export, PDF monthly report export.
- Notifications (`flutter_local_notifications`, inexact scheduling, boot receiver): daily check with actions, budget thresholds, recurring/salary reminders, monthly review.
- Scan: ML Kit on-device OCR (camera, receipt from gallery, screenshot from gallery), preprocessing, crop step, receipt + screenshot parsers, confidence, merchant mapping, duplicate detection, draft review.
- Security/reliability: PIN + biometric app lock, ZIP backup/restore with manifest + checksum, integrity check (incl. missing/orphan attachments), local error log, backup reminder banner (>30 days or never) on Home, Lainnya and Settings.
- Release: signed AAB/APKs (keystore in `~/finbro-keys/`), `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`, CI (`.github/workflows/ci.yml`).

## Change log (latest session, 1 Oktober 2026)

### UI revision to the reference (FinBro_Contoh_UI.png) — in progress, not yet checked on device

- Palette (`app_theme.dart` `FinColors`): light background `#F7F8FA`, surface `#FFFFFF`, accent `#4F46E5`, success `#16A34A`, danger `#DC2626`, warning `#D97706`; dark background `#0B0D10`, surface `#12151A`, accent `#6366F1`, success `#22C55E`, danger `#EF4444`, warning `#F59E0B`. New `accent` / `accentSoft` tokens.
- Theme: pill-shaped chips and segmented buttons; bottom nav without pill indicator, selected item in accent; progress bars accent on accent-tinted track (normal/attention budgets accent, warning amber, over red).
- Bottom nav: Goals tab replaced by **Analitik** (Laporan as a tab); "More" renamed **Lainnya**; Tujuan Keuangan added to Lainnya. `/reports` is now a shell branch, `/goals` a top-level route; monthly-review notification uses `go`.
- Home (`home_screen.dart`): avatar with initial + bell (opens Transaksi Berulang, dot when items await confirmation); Total Balance card with eye toggle (`SettingKeys.hideBalance`), change vs start of month ("↑ x% dari bulan lalu"), accent sparkline of the balance path this month (`BalanceSparkline`, `balancePath`), Income/Expense split inside the card; Available to Spend as a compact row; account chips moved to an "Akun" section. Separate Cash Flow card removed (trend now in the balance card; full chart stays in Laporan).
- Charts: income line/bars in accent, curved income line with fading fill; budget-vs-actual "Actual" in accent.
- Budget list: solid primary icon tiles (`IconAvatar(filled: true)`).
- Kalender: today shown as a filled accent circle; markers tinted (recorded = amber dot, no activity = accent dash, unknown = ring; shapes still carry meaning).
- Tujuan Keuangan: Semua / Aktif / Selesai filter chips; colored round goal icons per type (`GoalIcon`); full-width "Tambah Tujuan" button.
- Financial Health: rows with accent icon tile, value, share % and progress bar (`HealthMetric.percent`); benchmark/source kept; summary moved to an insight card with lightbulb at the bottom.
- Status: `flutter analyze` clean, `flutter test` 179 passing; release APK being built for the device check (light + dark screenshots).

### Earlier in this session

- **Fixed: OCR crashed in every release build.** R8 stripped ML Kit internals (`NullPointerException` in `mlkit_vision_common.zzmj.<init>` on every recognize call; debug builds unaffected). Added ML Kit keep rules in `android/app/proguard-rules.pro`. Verified on device: receipt → Rp 49.000 / 1 Okt 12:41 / Indomaret; GoPay screenshot → Rp 35.000 / Kopi Kenangan / "Terdeteksi: GoPay"; duplicate warning on re-scan.
- **Fixed: restore forgot backup history.** The restored DB carried its own old `last_backup_at` (none, since the backup is taken before that setting is written), so "Belum ada backup" reappeared right after a restore. `BackupService.restore` now keeps the newer of the live value and the backup date. Regression test in `backup_service_test.dart`.
- Added "Struk dari galeri" to Scan (FR-SCN-001 capture/import); before, receipts could only come from the camera.
- Large font scale (200%): segmented buttons used to break mid-word ("Expens/e") → new `SegmentLabel` in `fin_widgets.dart` used by every `SegmentedButton`. Home quick actions ("Tra…") and account-chip balances ("Rp 11.808.6…") now shrink instead of truncating; budget amount lines wrap; chart axis labels capped at 1.2× (they overlapped); More menu titles wrap to 2 lines.
- Frozen-schema/migration test `test/core/schema_migration_test.dart` + `test/generated_migrations/`.
- Backup reminder banner also on Home.
- Device test results (release build, Xiaomi 14T, Android 16): see STATUS.md → Verified.

## Not verified / open (see STATUS.md for the full list)

- Notification delivery in deep Doze (only reached `INACTIVE`, phone was charging over USB) and on other OEMs/Android versions.
- OCR on real photographed receipts (only synthetic images tested).
- TalkBack walkthrough (semantics labels exist, read via uiautomator; no screen-reader pass).
- Merchant mapping seed for Indonesian merchants (needs owner decision).

## Known limits (by design)

- Single device, no sync, no cloud. Backup is manual (reminder banner only).
- Notifications are inexact: Android delivers them within a window (measured: daily check 20:00 → 20:03, reminder 19:40 → 19:43, "Nanti" +1h with a 45-min window). After a reboot they are restored only after the first unlock.
- No SQLCipher: OS storage protection plus app lock.
- Recurring processing runs on app open/resume; no background service.
- Onboarding allocation steps by 5%; finer values in Settings → Planning.

## Build

```bash
flutter pub get
flutter test
ln -sf ~/finbro-keys/key.properties android/key.properties   # gitignored; remove after building
flutter build apk --release --split-per-abi
flutter build appbundle --release
rm android/key.properties
```

Without `android/key.properties` the release build silently falls back to the debug key (used by CI); never upload such a build.

Signing: `~/finbro-keys/finbro-release.jks`, alias `finbro`. Back it up off this machine; losing it blocks all future updates.
