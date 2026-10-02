# FinBro — Project Status

Date: 1 Oktober 2026 · Version 1.0.0+1 · `id.finbro.app`

**Status: feature-complete MVP, release build validated on one device (Xiaomi 14T).** Remaining work is owner actions and wider-device validation.

## Verified

- `flutter analyze`: no issues. `flutter test`: 179 passing (incl. frozen-schema check and restore/last-backup regression).
- Signed release APK/AAB (R8); signature `CN=FinBro` matches the keystore.
- Release build on Xiaomi 14T (Android 16 / HyperOS), installed via adb:
  - Onboarding, income/expense/transfer, edit (date change), delete with balance revert, transfer keeps total, budget 85% alert, recurring salary confirm.
  - Notifications: budget alert (instant), salary reminder (19:40 → delivered 19:43), daily check (19:50 → 19:52; 20:00 with screen off → 20:03), "Nanti" schedules one +1h reminder, "Tidak ada" marks the day NO_ACTIVITY from the background isolate and cancels the pending reminder; tapping is handled by the app.
  - Reboot: alarms gone while locked, all 34 restored by the boot receiver after first unlock.
  - OCR (synthetic Indomaret receipt and GoPay screenshot): amount, date/time, merchant, discount/tax/change read correctly; crop step works; duplicate warning on re-scan.
  - PDF monthly report (2 pages), CSV export, backup to Downloads, restore (preview → confirm → safety snapshot → data replaced, 1200-transaction backup restored in ~5 s).
  - App lock: PIN, wrong-PIN counter, biometric prompt on resume.
  - Offline (airplane mode): launch, add transaction, reports, budget, goals.
  - 200% font and 720×1280 @320 dpi: usable after the layout fixes in this session.
- Performance (release, 1200 transactions): activity launch 344–386 ms (warm cache, `am start -W`), Home content visible ≈2.7 s upper bound incl. uiautomator overhead, PSS ≈200 MB, list scroll ≈85–100 fps on the 120 Hz panel.

## Release blockers (owner actions)

1. Back up `~/finbro-keys/` to two offline locations.
2. Host `docs/PRIVACY_POLICY.md` at a public URL; fill the contact email placeholder.
3. Play listing assets (feature graphic, screenshots) — copy ready in `docs/PLAY_STORE.md`.
4. Closed test with 12+ testers for 14 days before Production (new personal Play accounts).

## Reliability gaps

- Notifications use `inexactAllowWhileIdle`: delivered within Android's window (minutes; "Nanti" up to +45 min). Deep Doze not reached in testing (phone charging over USB); other OEMs/Android versions untested.
- `allowBackup=false`, backup is manual (reminder banner after 30 days). Uninstall loses data.
- Database not encrypted (OS storage protection + app lock; see README).

## Validation pending

- OCR on real photographed receipts and other e-wallet/bank screenshots.
- TalkBack walkthrough.
- Fingerprint unlock itself (prompt verified; finger needs the owner).

## Needs owner decision

- Merchant mapping seed for common Indonesian merchants (Indomaret, Alfamart, GoFood, …) so scan suggests categories on first use.

## Docs

`README.md` (architecture, decisions), `SUMMARY.md` (what exists + change log), `CHANGELOG.md`, `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`.
