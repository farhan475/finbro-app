# Changelog

## Unreleased
- Security: FLAG_SECURE + no Recents thumbnail, INTERNET/ACCESS_NETWORK_STATE removed from the release manifest, device-transfer/cloud extraction disabled, deep linking off, release build refuses the debug key.
- Fixed: backups/safety snapshots never overwrite an earlier file; PIN salt+hash written atomically.
- Security: PIN hash/salt and lock settings are no longer included in backups and restore keeps this device's lock; wrong-PIN limiter persists across restarts with escalating cooldowns; restored attachment rows that did not come from the zip are neutralized.
- UI: lime accent `#5BEB12` replaces indigo (chart ramp derived from it, `accentText` for legible text on light surfaces); floating glass bottom navigation bar; negative balances/net cash flow red; goal "Development" uses theme monochrome.
- Database schema v2: 11 query indexes, `PRAGMA busy_timeout = 5000`.
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
