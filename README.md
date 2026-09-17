# Dokumentasi Barang Pecah - Flutter

Aplikasi kamera dokumentasi offline.

## Fitur
- Import Excel .xlsx
- Kolom A = Nomor, kolom B = Nama Barang
- Database Excel disimpan permanen menggunakan SharedPreferences
- Pencarian nomor real-time
- Kamera belakang
- Foto disimpan sebagai JPG ke /storage/emulated/0/Download
- Nama otomatis: Nomor_NamaBarang.jpg
- Anti overwrite: _1, _2, _3, dst.
- Reset database Excel
- Portrait dan UI tombol besar

## Build APK
Pastikan Flutter dan Android SDK sudah terpasang.

```bash
flutter pub get
flutter build apk --release
```

APK:
`build/app/outputs/flutter-apk/app-release.apk`

## Catatan
Pada Android modern, akses penyimpanan publik memiliki pembatasan Scoped Storage. Untuk perangkat Android tertentu, izin penyimpanan penuh dapat diperlukan.
