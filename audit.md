# FinBro — Security Audit & Patch Plan

> **Update (2 Okt, putaran 2):** selesai dan diuji: LOCK-001, LOCK-003 (PIN/lock settings dibuang dari backup, restore mempertahankan lock perangkat), LOCK-004 (limiter tersimpan permanen, cooldown 30s→1m→5m→15m→1j; memakai jam dinding, jadi memajukan jam perangkat masih bisa memperpendek cooldown), BACKUP-001 sebagian (path lampiran yang tidak berasal dari zip dinetralkan; `isManaged` dipakai di penghapusan; verifikasi user_version/trigger/view belum), PRIV-001, ANDROID-001, ROUTER-001, BUILD-001, atomic PIN write, snapshot tidak menimpa. Masih terbuka: LOCK-002, LOCK-005, BACKUP-001 (cek skema/trigger/view), BACKUP-002, NOTIF-001, CSV-001, LOG-001.


Audit read-only, 2 Okt 2026. Tidak ada temuan critical/high. 14 temuan medium/low.
**SecurityFix gagal (429) sebelum melaporkan hasil**; perubahan parsial mungkin ada di `lib/features/security`, `lib/features/backup`, `android/`, `attachment_storage.dart` (hash di isolate + `imageHash` sudah ada). Anggap semua item di bawah **belum selesai** sampai diverifikasi lewat `git diff`.

## Prioritas patch

### Medium
1. **FINBRO-LOCK-001 — tanpa FLAG_SECURE.** Recents/screenshot/screen record menampilkan data keuangan. Set `FLAG_SECURE` di `MainActivity.kt` (toggle via MethodChannel saat PIN aktif), `setRecentsScreenshotEnabled(false)` di API 33+, cover opaque saat `inactive`.
2. **FINBRO-LOCK-002 — relock bisa dilewati** lewat file picker/save dialog terbuka atau mundurkan jam. Catat waktu background dengan `Stopwatch` monoton, batasi durasi exempt (2–5 mnt). `app_lock_gate.dart`.
3. **FINBRO-BACKUP-001 — DB hasil restore dipercaya.** `local_path` lampiran bisa menunjuk file apa pun di sandbox (delete/copy). Netralkan path yang tidak berasal dari zip; cek `user_version`, tabel, hapus trigger/view; bersihkan `integrity_report`; tambah `AttachmentStorage.isManaged(path)` dan wajib dipakai di semua delete/read (`ledger_service.dart`, `attachment_repository.dart`, `integrity_check.dart`, `backup_service.dart`).
4. **FINBRO-LOCK-003 — kredensial PIN ikut backup.** Restore bisa mematikan lock atau mengunci permanen. Hapus `pin_hash`, `pin_salt`, `biometric_enabled`, `lock_timeout_seconds` dari salinan backup; saat restore pertahankan pengaturan lock perangkat; tulis salt+hash dalam satu transaksi. Opsional: HMAC dengan kunci Android Keystore.
5. **FINBRO-LOCK-004 — limiter PIN hanya di memori**, cooldown tetap 30 dtk. Persist hitungan + deadline (jam monoton), cooldown bertingkat 30s/1m/5m/15m/1j, pertimbangkan PIN minimal 6 digit.
6. **FINBRO-PRIV-001 — rilis memuat INTERNET + telemetri datatransport**, bertentangan dengan kebijakan privasi "tidak ada data dikirim". Tambah `tools:node="remove"` untuk `INTERNET`/`ACCESS_NETWORK_STATE` (dan komponen datatransport bila bisa), uji OCR di build release; atau koreksi privacy policy + Data Safety Play.

### Low
7. **BACKUP-002** — restore membaca/dekompres/hash seluruh zip di UI isolate tanpa batas ukuran (zip-bomb/OOM/ANR). Cek `PlatformFile.size`, batasi ukuran per-entry & total, tolak entry tak dikenal, jalankan di `Isolate.run`.
8. **BUILD-001** — release build diam-diam memakai debug key bila `key.properties` hilang. Lempar `GradleException`. `build.gradle.kts:50`.
9. **NOTIF-001** — notifikasi menampilkan nominal/akun/budget di lock screen. `NotificationVisibility.private` + versi publik generik.
10. **ANDROID-001** — `allowBackup=false` tidak menghentikan device-to-device transfer Android 12+. Tambah `dataExtractionRules` yang mengecualikan semuanya.
11. **LOCK-005** — overlay lock tidak memblokir fokus keyboard. `ExcludeFocus(excluding: locked)`, unfocus, `PopScope(canPop:false)`.
12. **ROUTER-001** — deep link dari app lain ke activity ter-export. Meta-data `flutter_deeplinking_enabled=false`.
13. **CSV-001** — netralisasi formula belum mencakup tab/CR awal; kolom nominal sebagai angka biasa. `csv_export.dart:51`.
14. **LOG-001** — `clear()` tidak menghapus `finbro.log.1`, rotasi hanya saat start, exception DB bisa membocorkan nilai. Rotasi di `_write`, hapus rotated file, log hanya `runtimeType` + kode hasil.

## Sudah diperiksa dan OK
Zip-slip (hanya nama file dasar), header SQLite + SHA-256 + `integrity_check` sebelum swap, swap DB atomik, perbandingan PIN constant-time & hashing di isolate, lock menutup cold start, rute tanpa side effect, payload notifikasi hanya dari app, `allowBackup=false`, wipe hanya `kDebugMode`, escaping CSV RFC 4180, ekspor lewat dialog sistem, keystore di luar repo.

## Rekomendasi jangka panjang
Hash PIN terikat Keystore; enkripsi DB (SQLCipher) bila threat model mencakup perangkat root/forensik; retensi safety snapshot.

## Kesiapan produksi
**Belum siap.** Urutan: (1) perbaiki 9 error analyze (lihat `bug.md` §0), (2) item medium 1–6 di atas, (3) bug uang P1/P2 di `bug.md`, (4) tuntaskan blocker owner di `STATUS.md` (privacy policy URL, aset Play, closed test 14 hari), (5) validasi perangkat nyata.
