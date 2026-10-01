# FinBro — Finance Brother App

Personal finance app for Android, offline-first, single user. The spec is the planning pack in `~/Downloads/finebro app/` (PRD, functional requirements, formulas, schema, UX, OCR, notification, security, roadmap, test plan).

## Stack

| Area | Choice |
|---|---|
| UI | Flutter 3.47 / Dart 3.13, Material 3, monochrome theme (light/dark), Inter font bundled offline |
| Database | SQLite via Drift (`lib/core/database`), schema v1 with a migration layer |
| State | flutter_riverpod 3 (manual providers, no codegen) |
| Routing | go_router (bottom nav: Home, Transaksi, Budget, Goals, More) |
| Charts | fl_chart |
| Notifications | flutter_local_notifications + timezone (local only) |
| OCR | google_mlkit_text_recognition (on-device, Latin) |
| Backup | zip (archive) + file_picker |
| App lock | PIN (salted, iterated SHA-256) + local_auth biometrics |

Package id: `id.finbro.app`. Currency: IDR, stored as integer rupiah.

## Structure

```text
lib/
├── app/            app.dart, root.dart (DB lifecycle/restore), router.dart, routes.dart, app_wiring.dart, theme/
├── core/
│   ├── database/   tables, enums, converters, seed, AppDatabase
│   ├── ledger/     LedgerService — the only write path for income/expense/transfer
│   ├── finance/    finance_math.dart (pure formulas) + FinanceService (read-side metrics)
│   ├── notifications/, settings/, storage/, formatting/, utilities/
├── features/       accounts, backup, budgets, calendar, categories, dashboard, goals, onboarding,
│                   planning, recurring, reports, scanner, security, settings, transactions
└── shared/         lookup providers, common widgets
```

Cross-feature hooks live in `lib/app/app_wiring.dart`:
- Ledger listeners run after every commit: budget threshold alerts and daily-activity marking.
- Lifecycle tasks run on app start and every resume: integrity check, recurring sync (instances, auto-confirm, reminders), and daily-check/monthly-review scheduling.

## Run / build

```bash
flutter pub get
dart run build_runner build        # only after changing Drift tables
flutter test                       # 174 tests
flutter run -d <android-device>
flutter build apk --release --split-per-abi   # per-CPU APKs, signed with the release key
flutter build appbundle --release             # AAB for Play Store
```

### Release signing

- Keystore: `~/finbro-keys/finbro-release.jks` (alias `finbro`, RSA 4096, valid 10 000 days).
- Passwords: `android/key.properties` (git-ignored), copy in `~/finbro-keys/key.properties`.
- **Back up `~/finbro-keys/` somewhere safe.** Losing it means existing installs can never be updated.
- Without `android/key.properties` the release build falls back to the debug key.

On desktop (Linux) the app runs for development. OCR, the camera, and notification scheduling are Android-only there.

## Decisions agreed with the user (not written in the planning pack)

- Schema additions:
  - `accounts.icon`
  - `budgets.attention_threshold` and `budgets.last_notified_threshold`
  - `recurring_rules.interval_days`, `month_of_year`, `reminder_offset_days`, `reminder_time`
  - `attachments.image_hash`
  - `planning_settings.flexible_residual_mode` and `planning_settings.user_reserve`
  - new table `merchant_mappings`
- Net Income = total confirmed income.
- Goal contributions are `goal_movements`; the money stays in its accounts. `goals.current_amount` is a rebuildable cache.
- Emergency Fund balance = sum of active goals of type `emergency`.
- Reserved money = active goal balances + the rest of this month's Family allocation + the manual user reserve.
- Upcoming obligations = open recurring expenses due by the end of the current month.
- Savings Rate numerator = net contributions to savings/emergency/development goals + net transfers into savings-type accounts, with no double counting.
- Daily check = per-date local notifications scheduled 30 days ahead and cancelled once a day is ACTIVE or NO_ACTIVITY. "Ingatkan nanti" fires once, +1 hour.
- Recurring instances and auto-confirm are processed when the app opens or resumes. There is no background service.
- No SQLCipher: the app relies on OS storage protection plus the app lock.
- The UI mixes Bahasa Indonesia and English financial terms, as in the mockup. Colors follow the monochrome spec, not the violet swatches in the mockup.

## Deviations / not done

- Onboarding allocation steps by 5%; finer values are edited in Settings → Planning & alokasi.
- The scan attachment stores the original photo; the cropped/rotated copy is only used for OCR.

## Verified on device (Xiaomi 14T, Android 16 / HyperOS 3)

- Install, onboarding, transactions, budget, dashboard.
- Daily check notification at the chosen time, with actions; "Tidak ada" writes NO_ACTIVITY from the background isolate without opening the app.
- Budget alerts at 85% and 100%, no repeated alert for the same threshold.
- App lock: wrong PIN rejected with attempt counter, correct PIN and fingerprint unlock, relock on resume.
- Backup to Downloads via the system save dialog (manifest checksum matches), CSV export, restore preview from a picked file.
- Pending on device: OCR accuracy on real receipts/screenshots, the new crop step, PDF export.

## Implementation status (planning-pack TODO.md)

| Section | Status |
|---|---|
| Foundation: project, package name, app icon, monochrome logo, light/dark theme, migration layer, Drift + Riverpod | Done |
| Core Data: all tables incl. goals/movements, recurring rules/instances, daily activity, planning/app settings | Done |
| Core Features: account/category CRUD, income/expense/transfer, search/filter, edit/delete/duplicate, balance/budget/goal/ATS/emergency engines | Done |
| Notifications: local service, daily check, budget threshold, recurring, salary reminder, monthly review | Done (scheduling verified in code/tests; delivery needs a device) |
| Reports: income vs expense, spending donut, top spending bar, budget vs actual, savings rate, emergency coverage, metrics panel | Done |
| OCR: device OCR (ML Kit), preprocessing, receipt + screenshot parsers, merchant mapping, confidence UI, duplicate detection | Done (accuracy spike on a target device pending) |
| Reliability: backup/export, restore/import, integrity check, app lock, local error log | Done; device performance test pending |
| Release: seeded categories, onboarding, empty states, debug demo-data toggle, release keystore | Done; device test of OCR/crop/PDF pending |
