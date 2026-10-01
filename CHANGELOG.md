# Changelog

## Unreleased
- Added in-app Bantuan screen (notification troubleshooting, backup guidance).

## 1.0.0+1 — first release
First FinBro release. See `SUMMARY.md`.

## Release policy
- Version lives in `pubspec.yaml` (`version: x.y.z+build`). Every Play upload needs a higher `+build`; keep `appVersion` in `about_screen.dart` in sync.
- Any Drift table change: bump `AppDatabase.currentSchemaVersion`, add a stepwise block in `onUpgrade`, and add a migration test that opens a database created at the previous version. Backups from older schemas must restore through the migration; backups from newer schemas are rejected (`backup_service.dart`).
- minSdk 24 (Android 7.0); targetSdk follows Flutter's default (36 on Flutter 3.47.2). Raise minSdk only when a dependency requires it.
