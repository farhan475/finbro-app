# Changelog

## Unreleased
- New: bank statement CSV import (Lainnya → Impor Mutasi Bank). Detects BCA, Mandiri, BNI, BRI, Jago, SeaBank and blu exports; manual column mapping when detection is unsure; per-row category and include/exclude; duplicate warning against existing transactions; imported rows post as confirmed with source `statement_import`. PDF statements are not supported yet.
- Security: backup restore now verifies the CRC32 of every unpacked zip entry against its header (archive 4.3.0 ignores its `verify` flag); corrupted entries are rejected instead of restored.
- Security: the error log redacts drift `InvalidDataException` messages, which embed the rejected row's column values.
- UI: floating navbar keeps the frosted-glass container but removes the selected pill; active icon and label use accent color and stronger weight only. Home add FAB is raised and Home scroll clearance is increased to avoid overlap.
- Android release: signed universal APK rebuilt after the UI correction. Device visual approval remains pending.
- Flutter Web/Chrome build is blocked by the current SQLite/Drift `dart:ffi` dependency; no successful Chrome UI smoke test was obtained.
- Fixed: recurring rule creation now joins the engine's serialized queue, preventing an in-flight sync from missing a newly created rule; report metrics reuse period summary and total balance instead of querying them again for available-to-spend.
- Changed: Net Amount Saved / Savings Rate count only net transfers into Savings accounts; goal contributions are goal progress, not savings (no double counting).
- Fixed: future-dated transactions no longer change balances before their date; deleting an auto-confirmed recurring transaction is not re-posted; development allocation ignores goal adjustments; emergency average no longer diluted by months before the first transaction (and cannot be NaN); budget end date covers the whole calendar day.
- Fixed: leaving the transaction form while saving no longer deletes the attachments being linked; back is blocked during save; the form's camera/gallery picker no longer triggers the app lock.
- Security: relock timed on a monotonic clock plus the wall clock (clock rollback locks), exempt operations capped at 5 minutes; lock screen blocks keyboard focus and Back.
- Security: restore checks `user_version` against the app and manifest, requires every table, drops triggers/views; size limits (512 MB zip, 256 MB per file, 1 GB unpacked), unknown entries rejected, too-large backups refused at creation; zip work off the UI thread; CSV neutralizes leading tab/CR; attachment deletes only inside app storage.
- Performance: recurring reminders rescheduled only when changed; Home computes balances once; budget usage and 6-month trend in single queries; transaction lists page by cursor instead of re-querying from the start.
- CI signs the release build with a throwaway key (the build refuses to run unsigned).
- Security: FLAG_SECURE + no Recents thumbnail, INTERNET/ACCESS_NETWORK_STATE removed from the release manifest, device-transfer/cloud extraction disabled, deep linking off, release build refuses the debug key.
- Fixed: backups/safety snapshots never overwrite an earlier file; PIN salt+hash written atomically.
- Security: PIN hash/salt and lock settings are no longer included in backups and restore keeps this device's lock; wrong-PIN limiter persists across restarts with escalating cooldowns; restored attachment rows that did not come from the zip are neutralized.
- UI: lime accent `#5BEB12` replaces indigo (chart ramp derived from it, `accentText` for legible text on light surfaces); floating glass bottom navigation bar; negative balances/net cash flow red; goal "Development" uses theme monochrome.
- Database schema v2 (historical baseline): 11 query indexes, `PRAGMA busy_timeout = 5000`; current schema v3 adds linked savings accounts for goals.
- Scanner: bounded image size, crop error state, picker exempt from relock, OCR dates outside 2000..today+365 ignored.
- Budget thresholds compared in integers (exact hits no longer missed).
- Recurring: rules never auto-post occurrences dated before the rule was created.
- Settings writes no longer recompute ledger providers (scoped, coalesced change ticks).
- Added in-app Bantuan screen (notification troubleshooting, backup guidance, FAQ).
- Frozen v1 database schema baseline.
- Backup reminder banner now also shown on Home.
- Frozen-schema/migration test (`test/core/schema_migration_test.dart`, helpers in `test/generated_migrations/`).
- Fixed OCR crashing in release (R8) builds: ML Kit keep rules.
- Fixed restore resetting "last backup" (backup reminder reappeared right after restoring).
- Scan: receipts can be picked from the gallery ("Struk dari galeri").
- Layout fixes for 200% font scale (segmented buttons, quick actions, account balances, budget amounts, chart axes, menu titles).

## 1.0.0+1 — first release
First FinBro release. See `SUMMARY.md`.

## Release policy
- Version lives in `pubspec.yaml` (`version: x.y.z+build`). Every Play upload needs a higher `+build`; keep `appVersion` in `about_screen.dart` in sync.
- `drift_schemas/drift_schema_v1.json` is the frozen v1 baseline. When bumping the schema run `dart run drift_dev schema dump lib/core/database/app_database.dart drift_schemas/` and generate migration test helpers from it (`drift_dev schema generate`).
- Any Drift table change: bump `AppDatabase.currentSchemaVersion`, add a stepwise block in `onUpgrade`, and add a migration test that opens a database created at the previous version. Backups from older schemas must restore through the migration; backups from newer schemas are rejected (`backup_service.dart`).
- minSdk 24 (Android 7.0); targetSdk follows Flutter's default (36 on Flutter 3.47.2). Raise minSdk only when a dependency requires it.
