# FinBro — Bug & Stability Backlog

Status setelah penyelesaian pekerjaan codebase: lihat item aktif di bawah. `flutter analyze` dan `flutter test`: lihat `STATUS.md` setelah verifikasi.

## Masih terbuka

- Lampiran belum punya checksum di manifest backup (DB dilindungi SHA-256; CRC32 per entry zip sudah diverifikasi saat restore sejak 2 Okt 2026).
- Backup dan restore memuat seluruh zip ke memori, sehingga batasnya 512 MB (zip), 256 MB per file, 1 GB total. Backup di atas batas ditolak saat dibuat. Untuk pengguna dengan sangat banyak lampiran perlu backup streaming (lihat roadmap).

## Belum divalidasi di perangkat
OCR struk foto asli, TalkBack, sidik jari, notifikasi di Doze dalam/OEM lain, perilaku lock baru (tombol back, fokus keyboard, batas 5 menit file picker), backup/restore dengan batas ukuran baru, impor mutasi CSV (picker di perangkat, parser terhadap file asli bank).

## Selesai (2 Okt 2026)

### Impor mutasi bank CSV (sesi terbaru; jangan dikerjakan ulang)
- Parser preset 7 bank (BCA, Mandiri, BNI, BRI, Jago, SeaBank, blu) + deteksi header/tanggal/amount, mapping manual bila tidak yakin (`csv_statement_parser.dart`, sudah ada sebelumnya) kini terhubung ke UI.
- Layar tinjau `/import` (menu Lainnya → Impor Mutasi Bank): pilih akun → pilih file CSV (lock-exempt, batas 20 MB) → tinjau per baris (include/exclude, kategori per baris, badge duplikat) → impor.
- Duplikat dicocokkan ke transaksi existing (akun sama, jumlah sama, tanggal ±2 hari, kesamaan deskripsi); baris diimpor sebagai `confirmed` dengan `sourceType: statement_import`; baris yang gagal validasi dilewati dan dihitung.
- Test: `test/statement_import/import_service_test.dart` (4) + `import_screen_test.dart` (2). Suite penuh 253 lulus.

### Uang / ledger
- [P1] Hapus transaksi auto-confirm recurring → instance ditutup `skipped`, tidak terposting ulang (+test).
- [P2] Edit jadwal rule tidak membuat instance kedua di periode settled; start date lampau tidak backfill/auto-post; perubahan rule diserialisasi; confirm/close atomik.
- [P2] `developmentAllocation` tidak menghitung `adjustment` (+test).
- [P2] `accountBalances` mengabaikan transaksi bertanggal setelah sekarang (+test).
- [P2] Form transaksi: lampiran yang sedang di-link tidak terhapus saat layar ditutup; `PopScope` selama menyimpan; image picker lewat `runExempt`.
- [P2, keputusan owner] Net Amount Saved = transfer bersih ke account Savings saja. Kontribusi goal = progres goal, tidak dihitung tabungan (+test).
- [P3] Threshold budget integer; `averageEssentialMonthly` dibagi bulan yang benar-benar punya riwayat, guard 0 (+test); batas atas budget per hari kalender, bukan 24 jam (+test); kategori nonaktif ditolak; `duplicate()` mempertahankan draft.

### Platform / stabilitas
- Safety snapshot tidak menimpa; salt+hash PIN satu transaksi; limiter PIN persisten bertingkat.
- Onboarding menjadwalkan daily check; reminder lama dibatalkan setelah restore; `root.dart` membuka ulang DB jika `close()` gagal; handler notifikasi background menangkap error; `LogScreen`/`BackupScreen` cek `mounted`, error CSV/baca/hapus backup ditangani.
- Zip encode/validate/sha256 berjalan di `Isolate.run`.

### Performa
- `dbChangesProvider` per tabel + coalesce 32 ms; tidak ada tulisan no-op saat resume.
- Daily check, monthly review dan reminder recurring hanya dijadwalkan ulang bila berubah (diff terhadap pending).
- Home: saldo dan ringkasan bulan dihitung sekali; `budgetUsages` 2 query (bukan N+1); `monthlyTrend` 1 query.
- `runApp` tidak menunggu init notifikasi; `app.dart` hanya watch setting yang dipakai.
- Daftar transaksi (Transaksi dan detail account): keyset pagination `(transactionAt, createdAt, rowid)`, bukan re-query dari offset 0 (+test).
