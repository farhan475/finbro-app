<p align="center">
  <img src="assets/brand/app_icon.png" alt="FinBro" width="112">
</p>

<h1 align="center">FinBro — Finance Brother App</h1>

<p align="center">
  Catat uang, atur budget, pantau target. <b>Offline, privat, tanpa akun.</b>
</p>

<p align="center">
  <a href="https://github.com/farhan475/finbro-app/releases/latest"><b>⬇ Unduh APK terbaru</b></a>
  · Android 7.0+ · Bahasa Indonesia
</p>

---

FinBro adalah aplikasi keuangan pribadi untuk Android yang bekerja sepenuhnya di perangkat. Semua data tersimpan di ponsel Anda, terenkripsi, dan tidak pernah dikirim ke server mana pun. Aplikasi ini tidak punya izin internet, tidak memakai akun online, tidak menampilkan iklan, dan tidak memasang pelacak.

## Fitur

**Catatan harian**
- Pemasukan, pengeluaran, dan transfer antar rekening, e-wallet, dan cash.
- Pencarian, filter, edit, duplikat, dan rekonsiliasi saldo akun.
- Multi mata uang (IDR, USD, SGD, MYR, EUR, GBP, JPY, AUD, CHF, CNY, HKD) dengan kurs manual. Semua total ditampilkan dalam rupiah.

**Perencanaan**
- Total saldo dan **Available to Spend**: uang yang aman dipakai setelah dikurangi dana cadangan, kewajiban terjadwal, dan buffer minimum.
- Budget bulanan per kategori dengan peringatan di 70%, 85%, dan 100% (bisa diubah per budget).
- Tujuan keuangan: dana darurat, tabungan, dan dana pengembangan, bisa ditautkan ke akun tabungan.
- Transaksi berulang (gaji, tagihan, langganan) dengan pengingat H/H-1/H-3, konfirmasi, atau auto-confirm.
- Kalender keuangan dan pengingat catatan harian.

**Laporan**
- Laporan bulanan dan tahunan: arus kas, komposisi pengeluaran, top spending, budget vs aktual, dan financial health.
- Ekspor laporan PDF dan transaksi CSV.

**Input cepat**
- Scan struk dan screenshot transaksi dengan OCR di perangkat. Hasilnya selalu berupa draf yang Anda periksa dulu.
- Impor mutasi rekening dari CSV (BCA, Mandiri, BNI, BRI, Jago, SeaBank, blu) atau PDF, termasuk PDF hasil scan. Ada tinjauan per baris dan peringatan duplikat.

**Widget layar utama**
- Kartu Total Balance dengan grafik saldo bulan ini.
- Saat diperbesar, widget menampilkan Income/Expense, lalu Available to Spend, budget, dan jadwal terdekat. Ketuk tiap bagian untuk membuka layarnya.
- Angka disamarkan saat kunci aplikasi aktif atau saldo disembunyikan.

**Keamanan & data**
- Database terenkripsi (SQLCipher) dengan kunci per perangkat.
- Kunci aplikasi dengan PIN dan sidik jari. Layar aplikasi tidak bisa di-screenshot atau direkam.
- Backup/restore manual, plus backup terenkripsi otomatis (AES-256-GCM) ke folder pilihan Anda secara harian atau mingguan.
- Proses latar belakang tiap ±6 jam untuk transaksi berulang, peringatan budget, widget, dan backup folder.

**Tampilan**
- Tema terang dan gelap, aksen lime, font Inter. Tata letak tetap rapi di ukuran font sampai 200%.

## Instalasi

1. Buka halaman [Releases](https://github.com/farhan475/finbro-app/releases/latest) dan unduh `FinBro-<versi>.apk`.
2. Buka file APK di ponsel. Izinkan "Instal aplikasi tidak dikenal" untuk browser atau file manager Anda bila diminta.
3. Ikuti onboarding: isi nama, tambahkan minimal satu akun beserta saldo awalnya, atur alokasi, lalu selesai.

APK ditandatangani dengan kunci rilis FinBro. Sidik jari sertifikat (SHA-256):
`12a40ea61091cac28b470f0ff4618b5a7f70ab2f7815a28b1e7cc8ae313fbc02`

> **Xiaomi / Oppo / Vivo:** aktifkan *Autostart* untuk FinBro agar pengingat dan widget tetap diperbarui saat aplikasi tidak dibuka. Di HyperOS, izinkan juga *"Add shortcuts to Home screen"* di izin aplikasi FinBro supaya widget bisa dipasang dari dalam aplikasi.

## Privasi

FinBro tidak mengumpulkan maupun membagikan data apa pun. Rilis Android tidak memiliki izin `INTERNET`. Menghapus aplikasi berarti menghapus semua datanya, jadi buat backup secara berkala. Selengkapnya: [Kebijakan Privasi](docs/PRIVACY_POLICY.md).

## Build dari source

Butuh Flutter 3.47 (Dart 3.13) dan Android SDK.

```bash
flutter pub get
flutter test
flutter run -d <perangkat-android>
```

Build release memerlukan `android/key.properties` (tidak ada di repo) dan tidak akan pernah memakai kunci debug. Arsitektur, struktur kode, dan detail build ada di [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Dokumentasi

| Dokumen | Isi |
|---|---|
| [DEVELOPMENT.md](docs/DEVELOPMENT.md) | Stack, struktur kode, build & signing, keputusan desain |
| [SUMMARY.md](docs/SUMMARY.md) | Ringkasan fitur dan catatan perubahan per sesi |
| [CHANGELOG.md](docs/CHANGELOG.md) | Riwayat perubahan |
| [STATUS.md](docs/STATUS.md) | Status proyek, validasi perangkat, pekerjaan terbuka |
| [BUGS.md](docs/BUGS.md) | Bug yang diketahui dan yang sudah diperbaiki |
| [AUDIT.md](docs/AUDIT.md) | Hasil audit keamanan |
| [PRIVACY_POLICY.md](docs/PRIVACY_POLICY.md) | Kebijakan privasi |
| [PLAY_STORE.md](docs/PLAY_STORE.md) | Teks listing Play Store |
