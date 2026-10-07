# FinBro — Security Audit & Patch Plan

Audit read-only 2 Okt 2026: tidak ada temuan critical/high, 14 temuan medium/low. **Semua 14 sudah ditutup di kode** (commit 2 Okt 2026) dan diuji dengan unit/widget test. Validasi di perangkat untuk perilaku lock dan batas backup masih tertunda (lihat `STATUS.md`).

## Status per temuan

| ID | Tingkat | Perbaikan |
|---|---|---|
| LOCK-001 | Medium | `FLAG_SECURE` aktif di build release/non-debuggable (screenshot/rekam layar/Recents kosong), thumbnail Recents dimatikan di API 33+ (`MainActivity.kt`). Build debug sengaja mengizinkan tangkapan layar untuk pengembangan. |
| LOCK-002 | Medium | `RelockTimer` (`lib/features/security/domain/relock_timer.dart`): waktu background diukur dengan jam sejak boot (`ClockChannel`, `elapsedRealtime` + boot count; boot berbeda → lock), `Stopwatch` monoton **dan** jam dinding; salah satunya mencapai batas → lock; jam mundur → lock. Operasi exempt (picker/dialog simpan/biometrik) maksimal 5 menit, lebih dari itu langsung lock. |
| LOCK-003 | Medium | PIN hash/salt dan pengaturan lock tidak ikut backup; restore mempertahankan lock perangkat. |
| LOCK-004 | Medium | Limiter PIN persisten, cooldown 30 dtk → 1 mnt → 5 mnt → 15 mnt → 1 jam. |
| LOCK-005 | Low | Saat lock: `ExcludeFocus` di atas app, fokus keyboard dilepas, tombol back ditelan (`didPopRoute`). |
| BACKUP-001 | Medium | DB hasil restore dibuka mentah dulu: `user_version` harus 1..versi app dan sama dengan manifest, semua tabel wajib ada, semua trigger/view di-drop, `integrity_report` dibersihkan. Path lampiran yang bukan dari zip dinetralkan; `AttachmentStorage.isManaged` dipakai di jalur hapus/baca ledger, attachment repo dan integrity check; `buildPackage` memakai `AttachmentStorage.isWithin` dengan direktori lampiran yang sama. |
| BACKUP-002 | Low | Batas 512 MB zip, 256 MB per entry, 1 GB total; ukuran entry yang melebihi header ditolak saat dekompres streaming (per chunk); nama entry di luar daftar, nama duplikat, entry terenkripsi dan kompresi selain STORE/deflate ditolak; validate dan build zip di `Isolate.run`. Backup yang melebihi batas ditolak saat dibuat. |
| PRIV-001 | Medium | `INTERNET`/`ACCESS_NETWORK_STATE` dihapus dari manifest release. **OCR di build release perlu dicek ulang di perangkat.** |
| BUILD-001 | Low | Release build gagal (`GradleException`) jika `key.properties` tidak ada. |
| NOTIF-001 | Low | Semua channel `NotificationVisibility.private`. Tidak ada versi publik eksplisit; isi disembunyikan Android hanya bila lock screen aman. |
| ANDROID-001 | Low | `dataExtractionRules` mengecualikan semuanya (device transfer + cloud). |
| ROUTER-001 | Low | `flutter_deeplinking_enabled=false`. |
| CSV-001 | Low | Netralisasi formula mencakup `= + - @ \t \r` di awal sel; nominal angka biasa. |
| LOG-001 | Low | Rotasi di setiap tulis, `clear()` menghapus `finbro.log.1`, error SQLite dicatat tanpa statement/parameter. |

## Sisa risiko yang diketahui
- Jam perangkat dimundurkan kira-kira sebesar lama perangkat tidur bisa menghindari relock. Penutupnya: `SystemClock.elapsedRealtime` via platform channel. **(Ditutup sejak audit: `elapsed_clock.dart` + `ClockChannel.kt` mengukur waktu sejak boot + boot count; dipakai `RelockTimer` dan limiter PIN.)**
- Error non-SQLite dicatat dengan `toString()`; drift `InvalidDataException` mungkin memuat nilai kolom. **(Ditutup 2 Okt 2026: `AppLogger.describeError` meredaksi `InvalidDataException`.)**
- CRC zip tidak diverifikasi oleh archive 4.3.0; lampiran belum punya checksum (DB dilindungi SHA-256). **(Ditutup penuh 2 Okt 2026: `BackupService.validateFile` → `_stageEntry` membandingkan CRC32 hasil dekompresi streaming dengan header zip untuk semua entry, dan manifest backup kini menyimpan SHA-256 per lampiran (`attachmentChecksums`) yang diverifikasi saat restore; kolom `attachments.file_sha256` (skema v4) diverifikasi integrity check.)**
- Impor mutasi CSV (2 Okt 2026) membaca file yang dipilih pengguna ke memori dengan batas 20 MB dan hanya mengimpor melalui `LedgerService`; tidak menambah permukaan izin (file picker SAF yang sudah ada). Tidak ada temuan baru.
- SQLCipher (7 Okt 2026): kunci database dapat dibaca tanpa autentikasi pengguna (diperlukan untuk WorkManager/notifikasi/widget headless), jadi enkripsi melindungi file database yang disalin keluar dari perangkat/forensik offline, bukan dari kode yang berjalan sebagai aplikasi di perangkat root. Backup zip manual & safety snapshot berisi SQLite plaintext (portabel); `finbro.sqlite.plain-pending` (plaintext) bertahan sampai app dibuka ulang setelah migrasi pertama.
- WorkManager (7 Okt 2026) menjalankan engine Dart headless dengan akses DB yang sama; tidak menambah izin runtime atau jaringan (`ACCESS_NETWORK_STATE` dari work-runtime ditolak di manifest). work-runtime menambah izin normal `WAKE_LOCK` dan `FOREGROUND_SERVICE` ke manifest gabungan (FinBro tidak memakai foreground service). Impor PDF hasil scan merender halaman ke file PNG sementara di cache app, dihapus per halaman dan di akhir proses.

## Sudah diperiksa dan OK
Zip-slip (hanya nama file dasar), header SQLite + SHA-256 + `integrity_check` sebelum swap, swap DB atomik, perbandingan PIN constant-time & hashing di isolate, lock menutup cold start, rute tanpa side effect, payload notifikasi hanya dari app, `allowBackup=false`, wipe hanya `kDebugMode`, escaping CSV RFC 4180, ekspor lewat dialog sistem, keystore di luar repo.

## Rekomendasi jangka panjang
- ~~Backup terenkripsi (kunci dari passphrase pengguna) ke folder pilihan pengguna; prasyarat untuk sync cloud.~~ **(Selesai: domain 3 Okt, UI + restore `.finbro` 7 Okt 2026. Format v2: AES-256-GCM per chunk 1 MiB dengan nonce STREAM (prefix + indeks + flag chunk terakhir) dan header sebagai AAD — chunk yang ditukar/dipotong/ditambah gagal autentikasi; kunci Argon2id dari passphrase ≥ 8 karakter, disimpan di `flutter_secure_storage` perangkat; restore mendekripsi ke file sementara lalu `validateFile` streaming.)**
- ~~Hash PIN terikat Android Keystore; SQLCipher bila threat model mencakup perangkat root/forensik.~~ **(Keystore selesai 3 Okt 2026: `PinVerifierChannel.kt` — HMAC-SHA256 kunci non-ekspor AndroidKeyStore, constant-time compare, kegagalan eksplisit tanpa downgrade; migrasi otomatis hash legacy. SQLCipher selesai 7 Okt 2026: kunci acak 256-bit per perangkat di flutter_secure_storage (AES-GCM dibungkus kunci Android Keystore, `resetOnError: false`), `PRAGMA key` mentah + cek `cipher_version` di setiap koneksi (fail-closed), kunci tidak pernah di-log/di-backup; migrasi plaintext lewat salinan terverifikasi, plaintext disimpan sampai proses berikutnya membaca balik kunci karena flutter_secure_storage menulis dengan `SharedPreferences.apply()`.)**
- ~~Retensi safety snapshot (hapus otomatis yang lama).~~ **(Selesai 2 Okt 2026: `pruneSafetySnapshots` menyimpan 2 terbaru; +test.)**
- CRC zip: ditutup penuh (per-entry CRC saat validate streaming + SHA-256 per lampiran di manifest + kolom `file_sha256` skema v4).
