# FinBro Implementation Summary

Date: 1 Oktober 2026 · Version 1.0.0+1 · Application ID `id.finbro.app`
Verified: `flutter analyze` clean, `flutter test` 174 passing.

Spec: planning pack in `~/Downloads/finebro app/`. Details and decisions: `README.md`. Release readiness and open work: `STATUS.md`.

## Implemented (all planning-pack MVP phases 0–6)

- Foundation: Flutter, Drift SQLite (schema v1, migration layer present, no upgrades yet), Riverpod, go_router, light/dark monochrome theme, Inter font, monochrome logo/icon.
- Data: accounts, categories (seeded), transactions, attachments, budgets, goals + goal_movements, recurring rules/instances, daily_activity, planning_settings, app_settings, merchant_mappings.
- Logic: ledger as the single write path; balances, available-to-spend, emergency fund, savings rate, budget usage, upcoming obligations (`lib/core/finance`).
- Features: account/category CRUD, income/expense/transfer, filter/search, edit/delete/duplicate, account reconciliation, budgets, goals, recurring with confirm/skip/auto-confirm, calendar, planning settings, onboarding, empty states, demo data (debug).
- Reports: income vs expense, spending donut, top spending, budget vs actual, metrics panel, CSV export, PDF monthly report export.
- Notifications (`flutter_local_notifications`, inexact scheduling): daily check with actions, budget thresholds, recurring/salary reminders, monthly review.
- Scan: ML Kit on-device OCR, preprocessing, crop step, receipt + screenshot parsers, confidence, merchant mapping, duplicate detection, draft review.
- Security/reliability: PIN + biometric app lock, ZIP backup/restore with manifest + checksum, integrity check, local error log.
- Release: signed AAB/APKs (keystore in `~/finbro-keys/`), `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`.

## Not verified / open (see STATUS.md for the full list)

- OCR accuracy on real receipts and e-wallet screenshots; crop step on device.
- PDF export on device.
- Performance baseline (no measurements exist yet).
- Notification delivery with Doze/battery saver, after reboot, and on Android versions other than the Xiaomi 14T (Android 16).
- Release (R8) build behaviour end-to-end.
- Real Indonesian merchant seed data (only user-added mappings exist).
- DB upgrade test (schema is still v1).

## Known limits (by design)

- Single device, no sync, no cloud. Backup is manual; there is no backup reminder yet.
- No SQLCipher: OS storage protection plus app lock.
- Recurring processing runs on app open/resume; no background service.
- Onboarding allocation steps by 5%; finer values in Settings → Planning.

## Build

```bash
flutter pub get
flutter test
flutter build apk --release --split-per-abi
flutter build appbundle --release   # needs android/key.properties
```

Signing: `~/finbro-keys/finbro-release.jks`, alias `finbro`. Back it up off this machine; losing it blocks all future updates.
