# Kebijakan Privasi FinBro / FinBro Privacy Policy

Terakhir diperbarui / Last updated: 7 Oktober 2026

## Bahasa Indonesia

FinBro (Finance Brother App) adalah aplikasi keuangan pribadi yang bekerja offline.

**Data yang kami kumpulkan: tidak ada.** FinBro tidak memiliki server, akun, analitik, iklan, maupun pelacak. Semua data (transaksi, akun, budget, target, kurs, foto struk/lampiran, pengaturan) disimpan hanya di perangkat Anda, pada penyimpanan privat aplikasi. Aplikasi tidak mengirim data ke pihak mana pun dan tidak meminta izin internet.

**Izin yang digunakan**
- Kamera: memotret struk untuk dibaca (OCR). Pengenalan teks berjalan di perangkat (Google ML Kit, model terpasang); gambar tidak dikirim keluar.
- Notifikasi, alarm & pengingat, dan menyala ulang setelah boot: pengingat harian, jatuh tempo transaksi berulang, peringatan budget, ringkasan bulanan; pengingat dijadwalkan ulang setelah perangkat dinyalakan. Sekitar setiap 6 jam FinBro memproses transaksi berulang dan memperbarui widget di latar belakang (Android WorkManager), sepenuhnya di perangkat.
- Biometrik: membuka kunci aplikasi dengan sidik jari/wajah (opsional). Data biometrik dikelola sistem Android dan tidak dapat diakses FinBro.
- Berkas/folder: hanya melalui pemilih berkas sistem saat Anda mengekspor atau memulihkan backup, CSV, atau PDF, dan saat Anda mengimpor file mutasi bank (CSV/PDF), yang dibaca di perangkat (PDF hasil scan dibaca dengan OCR di perangkat). Bila Anda mengaktifkan backup terenkripsi ke folder, FinBro menyimpan izin akses ke folder yang Anda pilih sampai Anda mematikannya.

**Backup.** Backup manual dibuat atas permintaan Anda sebagai berkas ZIP lokal yang tidak dienkripsi; Anda bertanggung jawab atas tempat penyimpanannya. Backup ke folder (opsional) dienkripsi dengan AES-256-GCM memakai kunci yang diturunkan dari passphrase Anda (Argon2id); kunci disimpan di penyimpanan aman Android pada perangkat ini dan passphrase tidak dapat dipulihkan oleh siapa pun. Menghapus aplikasi menghapus seluruh data aplikasi; backup yang Anda simpan di luar aplikasi tetap ada.

**Widget layar utama.** Jika Anda memasang widget, total saldo tampil di layar utama. Selama kunci aplikasi (PIN) aktif atau saldo disembunyikan, widget hanya menampilkan `••••••`.

**Keamanan.** Database FinBro dienkripsi (SQLCipher, AES-256) dengan kunci acak yang dibuat dan disimpan di penyimpanan aman Android pada perangkat ini; kunci tidak pernah ikut backup. Kunci aplikasi (PIN disimpan sebagai hash bergaram yang diikat ke kunci Android Keystore perangkat) melindungi tampilan aplikasi dan bukan pengganti enkripsi perangkat.

**Anak-anak.** FinBro tidak ditujukan untuk anak di bawah 13 tahun.

**Perubahan & kontak.** Perubahan kebijakan akan dicantumkan di halaman ini. Kontak: TODO-ISI-EMAIL-ANDA

## English

FinBro (Finance Brother App) is an offline personal finance app.

**Data we collect: none.** FinBro has no server, accounts, analytics, ads, or trackers. All data (transactions, accounts, budgets, goals, exchange rates, receipt images/attachments, settings) stays on your device in app-private storage. The app sends no data to anyone and requests no internet permission.

**Permissions**
- Camera: capture receipts for OCR. Text recognition runs on-device (Google ML Kit, bundled model); images never leave the device.
- Notifications, alarms & reminders, and run at startup: daily check reminders, recurring due dates, budget alerts, monthly review; reminders are rescheduled after a reboot. About every 6 hours FinBro processes recurring transactions and refreshes the widget in the background (Android WorkManager), entirely on-device.
- Biometrics: optional app unlock. Biometric data is handled by Android and is not accessible to FinBro.
- Files/folders: only through the system picker when you export or restore a backup, CSV, or PDF, and when you import a bank statement file (CSV/PDF), which is read on-device (scanned PDFs are read with on-device OCR). If you enable encrypted folder backups, FinBro keeps access to the folder you chose until you turn it off.

**Backups.** Manual backups are unencrypted ZIP files created on your request; you are responsible for where you store them. Optional folder backups are encrypted with AES-256-GCM using a key derived from your passphrase (Argon2id); the key is kept in Android secure storage on this device and nobody can recover a lost passphrase. Uninstalling the app deletes all app data; backups you saved elsewhere remain.

**Home-screen widget.** If you add the widget, your total balance appears on the home screen. While the app lock (PIN) is on or balances are hidden, it only shows `••••••`.

**Security.** FinBro's database is encrypted (SQLCipher, AES-256) with a random key created and kept in Android secure storage on this device; the key is never included in backups. The app lock (PIN stored as a salted hash bound to an Android Keystore key on the device) protects the app UI and is not a replacement for device encryption.

**Children.** FinBro is not directed to children under 13.

**Changes & contact.** Changes will be posted on this page. Contact: TODO-FILL-YOUR-EMAIL
