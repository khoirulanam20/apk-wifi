# Changelog

Semua perubahan penting pada proyek ini akan didokumentasikan di file ini.

Format mengikuti prinsip [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
dan proyek ini menggunakan [Semantic Versioning](https://semver.org/lang/id/).

## [Unreleased]

## [1.1.0] - 2026-05-28

### Added
- Menambahkan header (`AppBar`) pada `WebShell` dengan tinggi ringkas, tombol refresh, dan area judul yang mendukung aksi double-tap untuk memicu reload.
- Menambahkan indikator loading (`LinearProgressIndicator`) di bawah header untuk menampilkan status pemuatan halaman dan proses refresh.
- Menambahkan dukungan native Android `SwipeRefreshLayout` di `MainActivity` agar WebView mendukung gesture pull-to-refresh.
- Menambahkan pelaporan status scroll dari WebView ke native menggunakan method channel (`updateScrollState`) untuk menentukan apakah posisi konten sedang di paling atas.
- Menambahkan injeksi JavaScript listener pada WebView untuk membaca offset scroll dari halaman utama maupun elemen scrollable.

### Changed
- Mengubah alur refresh agar sinkron antara Flutter dan native melalui method channel:
  - Native memanggil `onRefresh` saat user melakukan pull gesture.
  - Flutter memanggil `refreshComplete` saat reload halaman selesai.
- Mengubah perilaku pull-to-refresh agar hanya aktif ketika konten berada di posisi paling atas, sehingga mengurangi refresh tidak sengaja saat user sedang menggulir konten.
- Mengoptimalkan pembaruan progress loading agar tidak memicu rebuild terlalu sering dengan pembatasan perubahan nilai progress.

### Technical Notes
- Method channel yang digunakan: `com.bintangkecil.swf/native`.
- Method yang terlibat: `enablePullToRefresh`, `onRefresh`, `refreshComplete`, dan `updateScrollState`.
- `SwipeRefreshLayout` membungkus `FlutterView` pada level native Android, lalu callback `setOnChildScrollUpCallback` dipakai untuk memblok gesture refresh ketika child masih bisa scroll ke atas.

