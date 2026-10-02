# FinBro — Bug & Stability Backlog

Status per 2 Okt 2026 (setelah Fase 0–5). Semua item dari audit read-only 4 agen sudah dicek ulang terhadap kode dan ditutup, kecuali yang tercantum di "Masih terbuka".
`flutter analyze`: bersih. `flutter test`: lihat `STATUS.md`.

## Masih terbuka (kecil)

- `RecurringRepository.create` menyisipkan rule di luar antrean `_serialized` engine. Tidak bisa memposting ganda (UNIQUE `(rule, due_date)` + close atomik), tapi sync yang sedang berjalan bisa melewatkan rule baru sampai sync berikutnya.
- Transaksi bertanggal masa depan baru masuk saldo saat provider dihitung ulang (perubahan DB atau buka ulang app), bukan tepat saat jamnya lewat.
- `FinanceService.metrics()` masih menghitung `summary`/`totalBalance` lebih dari sekali per panel Laporan (bukan jalur Home).
- Relock: jika jam perangkat dimundurkan kira-kira sebesar lama perangkat tidur, cooldown/relock bisa terlewat. Penutupnya butuh `SystemClock.elapsedRealtime` via platform channel.
- Restore: archive 4.3.0 mengabaikan verifikasi CRC zip. DB tetap dilindungi SHA-256 di manifest; lampiran belum punya checksum.
- Backup dan restore memuat seluruh zip ke memori, sehingga batasnya 512 MB (zip), 256 MB per file, 1 GB total. Backup di atas batas ditolak saat dibuat. Untuk pengguna dengan sangat banyak lampiran perlu backup streaming (lihat roadmap).

## Belum divalidasi di perangkat
OCR struk foto asli, TalkBack, sidik jari, notifikasi di Doze dalam/OEM lain, perilaku lock baru (tombol back, fokus keyboard, batas 5 menit file picker), backup/restore dengan batas ukuran baru.

## Selesai (2 Okt 2026)

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
