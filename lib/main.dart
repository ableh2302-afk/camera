import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    cameras = await availableCameras();
  } catch (_) {
    cameras = <CameraDescription>[];
  }

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  runApp(const DokumentasiApp());
}

class DokumentasiApp extends StatelessWidget {
  const DokumentasiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dokumentasi Barang Pecah',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.green,
        scaffoldBackgroundColor: const Color(0xFFF5F8F5),
        inputDecorationTheme: const InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(14)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  CameraController? _camera;
  final _nomorController = TextEditingController();

  Map<String, String> _barang = {};
  String _namaBarang = '';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _loadDatabase();
    await _initializeCamera();

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();

    if (Platform.isAndroid) {
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;

    final selected = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    final controller = CameraController(
      selected,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await controller.initialize();
      if (mounted) {
        setState(() => _camera = controller);
      } else {
        await controller.dispose();
      }
    } catch (_) {
      await controller.dispose();
    }
  }

  Future<void> _loadDatabase() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('excel_database');

    if (raw == null || raw.isEmpty) return;

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _barang = decoded.map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        );
      }
    } catch (_) {
      _barang = {};
    }
  }

  Future<void> _saveDatabase() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('excel_database', jsonEncode(_barang));
  }

  Future<void> _importExcel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: false,
      );

      if (result == null || result.files.single.path == null) return;

      final file = File(result.files.single.path!);
      final bytes = await file.readAsBytes();
      final workbook = Excel.decodeBytes(bytes);

      if (workbook.tables.isEmpty) {
        _showMessage('Excel tidak memiliki sheet.');
        return;
      }

      final sheet = workbook.tables.values.first;
      final rows = sheet.rows;

      if (rows.isEmpty) {
        _showMessage('Excel tidak memiliki data.');
        return;
      }

      final Map<String, String> imported = {};

      // Baris pertama dianggap header: A = Nomor, B = Nama Barang.
      for (int i = 1; i < rows.length; i++) {
        if (rows[i].length < 2) continue;

        final nomor = rows[i][0]?.value?.toString().trim() ?? '';
        final nama = rows[i][1]?.value?.toString().trim() ?? '';

        if (nomor.isNotEmpty && nama.isNotEmpty) {
          imported[nomor] = nama;
        }
      }

      if (imported.isEmpty) {
        _showMessage('Tidak ditemukan data pada kolom A dan B.');
        return;
      }

      _barang = imported;
      await _saveDatabase();

      if (mounted) setState(() {});

      _showMessage('Berhasil import ${_barang.length} data barang.');
    } catch (e) {
      _showMessage('Gagal membaca Excel: $e');
    }
  }

  Future<void> _resetDatabase() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset Database'),
        content: const Text(
          'Semua data Excel yang tersimpan di aplikasi akan dihapus. '
          'Foto yang sudah ada di Download tidak akan ikut terhapus.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('BATAL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('HAPUS'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('excel_database');

    setState(() {
      _barang.clear();
      _namaBarang = '';
      _nomorController.clear();
    });

    _showMessage('Database Excel berhasil dihapus.');
  }

  void _searchNumber(String value) {
    final nomor = value.trim();

    setState(() {
      _namaBarang = _barang[nomor] ?? '';
    });
  }

  String _cleanFileName(String text) {
    var cleaned = text.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    cleaned = cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
    cleaned = cleaned.replaceAll(RegExp(r'[. ]+$'), '');
    return cleaned.isEmpty ? 'Barang' : cleaned;
  }

  Future<Directory> _downloadDirectory() async {
    final directory = Directory('/storage/emulated/0/Download');

    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }

    return directory;
  }

  Future<File> _uniqueFile(Directory directory, String baseName) async {
    var candidate = File('${directory.path}/$baseName.jpg');

    if (!await candidate.exists()) return candidate;

    int index = 1;
    while (true) {
      candidate = File(
        '${directory.path}/${baseName}_$index.jpg',
      );

      if (!await candidate.exists()) return candidate;
      index++;
    }
  }

  Future<void> _takePhoto() async {
    if (_saving) return;

    final nomor = _nomorController.text.trim();

    if (nomor.isEmpty) {
      _showMessage('Masukkan nomor barang terlebih dahulu.');
      return;
    }

    if (_namaBarang.isEmpty) {
      _showMessage('Nomor barang tidak ditemukan.');
      return;
    }

    final camera = _camera;

    if (camera == null || !camera.value.isInitialized) {
      _showMessage('Kamera belum siap.');
      return;
    }

    setState(() => _saving = true);

    try {
      final photo = await camera.takePicture();

      final directory = await _downloadDirectory();
      final safeName = _cleanFileName(_namaBarang);
      final baseName = '${_cleanFileName(nomor)}_$safeName';

      final target = await _uniqueFile(directory, baseName);
      await File(photo.path).copy(target.path);

      if (!mounted) return;

      _nomorController.clear();
      setState(() {
        _namaBarang = '';
        _saving = false;
      });

      _showMessage('Foto tersimpan: ${target.path}');
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
      }
      _showMessage('Gagal menyimpan foto: $e');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  void dispose() {
    _camera?.dispose();
    _nomorController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final found = _namaBarang.isNotEmpty;
    final typed = _nomorController.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Dokumentasi Barang Pecah',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 54,
                    child: FilledButton.icon(
                      onPressed: _importExcel,
                      icon: const Icon(Icons.upload_file),
                      label: const Text(
                        'IMPORT EXCEL',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 54,
                  child: OutlinedButton(
                    onPressed: _resetDatabase,
                    child: const Icon(Icons.delete_outline),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            Card(
              elevation: 0,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    const Icon(Icons.inventory_2_outlined),
                    const SizedBox(width: 10),
                    Text(
                      '${_barang.length} data barang tersimpan',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            TextField(
              controller: _nomorController,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
              ],
              onChanged: _searchNumber,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
              decoration: const InputDecoration(
                labelText: 'Nomor Barang',
                hintText: 'Ketik nomor barang...',
                prefixIcon: Icon(Icons.tag),
              ),
            ),

            const SizedBox(height: 8),

            AnimatedSwitcher(
              duration: const Duration(milliseconds: 150),
              child: found
                  ? Container(
                      key: const ValueKey('found'),
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Text(
                        _namaBarang,
                        style: const TextStyle(
                          color: Colors.blue,
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : typed
                      ? const Padding(
                          key: ValueKey('notfound'),
                          padding: EdgeInsets.all(8),
                          child: Text(
                            '⚠️ Nomor tidak ditemukan',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      : const SizedBox(
                          key: ValueKey('empty'),
                          height: 8,
                        ),
            ),

            const SizedBox(height: 14),

            AspectRatio(
              aspectRatio: 3 / 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  color: Colors.black,
                  child: _camera != null &&
                          _camera!.value.isInitialized
                      ? CameraPreview(_camera!)
                      : const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.no_photography_outlined,
                                color: Colors.white,
                                size: 52,
                              ),
                              SizedBox(height: 12),
                              Text(
                                'Kamera belum tersedia',
                                style: TextStyle(color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            SizedBox(
              height: 72,
              child: FilledButton.icon(
                onPressed: _saving ? null : _takePhoto,
                icon: _saving
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(
                        Icons.camera_alt,
                        size: 30,
                      ),
                label: Text(
                  _saving
                      ? 'MENYIMPAN...'
                      : 'JEPRET & SIMPAN FOTO',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 10),

            const Text(
              'Foto disimpan sebagai JPG di folder Download. '
              'Jika nama file sudah ada, aplikasi otomatis menambahkan _1, _2, dst.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.black54,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
