# FinBro — Project Status

Date: 1 Oktober 2026 · Version 1.0.0+1 · `id.finbro.app`

**Status: feature-complete MVP. Not yet production-validated.** Build, analyzer and tests pass; device validation is partial (Xiaomi 14T only).

## Verified

- `flutter analyze`: no issues. `flutter test`: 174 passing.
- Device (Xiaomi 14T, Android 16/HyperOS 3): install, onboarding, transactions, budget alerts, daily-check notification and actions, app lock (PIN + fingerprint), backup to Downloads, CSV export, restore preview.

## Release blockers

1. Back up `~/finbro-keys/` to two offline locations (not done by tooling).
2. Host `docs/PRIVACY_POLICY.md` at a public URL; fill the contact email placeholder.
3. Play listing assets (feature graphic, screenshots) — copy ready in `docs/PLAY_STORE.md`.
4. Test the release (R8-minified) build end-to-end, then rebuild and verify the AAB signature.
5. New personal Play accounts: closed test with 12+ testers for 14 days before Production.

## Reliability gaps

- Notifications use `inexactAllowWhileIdle`; the 20:30 daily check may be late. Untested under Doze, after reboot, and on other Android versions/OEMs.
- DB schema is v1 with no upgrade path tested; add a migration test before the first schema change.
- `allowBackup=false` and backup is manual only (no reminder). Uninstall loses data.
- Database is not encrypted (decision to document).

## Validation pending

- OCR on real receipts/screenshots; crop step; PDF export on device.
- Performance baseline (cold start, 1000-row scroll, memory) — no measurements recorded yet.
- Small screens, 200% font scale, TalkBack, offline (airplane mode) pass.

## Spec gaps to check

- Archived-account rules, custom recurring intervals and H-3/H-1/H reminders, orphan-attachment integrity check, ratio metrics with zero denominators — need tests or confirmation.
- Merchant mapping seed for Indonesian vendors (needs owner approval).

## Docs

`README.md` (architecture, decisions), `SUMMARY.md` (what exists), `docs/PRIVACY_POLICY.md`, `docs/PLAY_STORE.md`.
