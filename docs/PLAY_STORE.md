# Play Store Listing — FinBro

Application ID: `id.finbro.app` (final; cannot change after first upload)
Version: 1.0.0 (build 1)

## Indonesia

**Judul (maks 30):** FinBro: Catatan Keuangan

**Deskripsi singkat (maks 80):** Catat uang, atur budget, pantau target. Offline, privat, tanpa akun.

**Deskripsi lengkap:**
FinBro adalah teman keuangan pribadi yang bekerja sepenuhnya offline. Data Anda tersimpan hanya di ponsel.

- Catat pemasukan, pengeluaran, dan transfer antar rekening/e-wallet/cash
- Total saldo dan "Available to Spend" yang jelas
- Budget bulanan per kategori dengan peringatan di 85% dan 100%
- Target keuangan: dana darurat, tabungan, dana pengembangan
- Transaksi berulang (gaji, tagihan, langganan) dengan pengingat dan konfirmasi
- Kalender keuangan dan pengingat catatan harian
- Laporan: arus kas, komposisi pengeluaran, top spending, budget vs aktual
- Scan struk dan screenshot transaksi (OCR di perangkat) — selalu berupa draf yang Anda periksa
- Backup/restore, ekspor CSV dan PDF
- Kunci aplikasi PIN + sidik jari
- Tema terang dan gelap

Tanpa akun. Tanpa iklan. Tanpa pelacak.

## English

**Title:** FinBro: Personal Finance

**Short:** Track money, set budgets, hit goals. Offline, private, no account.

**Full:** FinBro is an offline personal finance companion. Your data stays on your phone. Track income, expenses and transfers; see balance and available-to-spend; set monthly budgets with alerts; manage goals, recurring items and a financial calendar; view reports; scan receipts on-device (always a draft you review); back up/restore, export CSV/PDF; PIN + biometric lock; light/dark theme. No account, no ads, no trackers.

## Release notes v1.0.0

ID: Rilis pertama FinBro.
EN: First release of FinBro.

## Data safety form

- Data collected: none. Data shared: none.
- Data encrypted in transit: n/a (no network transfer).
- Deletion: uninstall removes all app data.
- Privacy policy URL: host `docs/PRIVACY_POLICY.md` publicly (e.g. GitHub Pages) and paste URL.

## Exact alarm declaration

- The manifest declares `SCHEDULE_EXACT_ALARM` only (never `USE_EXACT_ALARM`, which Play reserves for alarm-clock/calendar apps). It is user-grantable and denied by default on Android 14+ for new installs.
- Use: user-scheduled reminders (salary and other recurring transactions, daily check-in, "Ingatkan nanti", monthly review) fire at the time the user picked. Toggle: Pengaturan → Notifikasi → "Pengingat tepat waktu" (default on); the "Izinkan" button opens the system "Alarm & pengingat" screen.
- Without the permission, or with the toggle off, reminders fall back to inexact alarms; no feature is blocked. If the App content → "Exact alarm" declaration form appears in Play Console, answer: core functionality = user-set reminders; the app works without the permission.

## Assets checklist

- [ ] App icon 512x512 (`assets/brand/app_icon.png`, resize)
- [ ] Feature graphic 1024x500
- [ ] 2–8 phone screenshots (Home, Activity, Budget, Goals, Reports, Scan, Calendar)
- [ ] Category: Finance; content rating questionnaire
- [ ] New personal accounts: closed test with 12+ testers for 14 days before Production
