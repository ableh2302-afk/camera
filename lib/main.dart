import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

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

  await SystemChrome.setEnabledSystemUIMode(
    SystemUiMode.immersiveSticky,
  );

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
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
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

class _HomePageState extends State<HomePage>
    with WidgetsBindingObserver {
  CameraController? _camera;

  final TextEditingController _nomorController =
      TextEditingController();

  final FocusNode _nomorFocus = FocusNode();

  Map<String, String> _barang = {};

  String _namaBarang = '';

  bool _loading = true;
  bool _saving = false;
  bool _grid = false;
  bool _settingsOpen = false;
  bool _excelMenuOpen = false;
  bool _numberEditorOpen = false;

  FlashMode _flashMode = FlashMode.off;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  int _timerSeconds = 0;

  int _cameraIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;

    if (camera == null || !camera.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      camera.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _reinitializeCurrentCamera();
    }
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _loadDatabase();
    await _initializeCamera();

    if (mounted) {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();

    if (Platform.isAndroid) {
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) {
      return;
    }

    if (_cameraIndex >= cameras.length) {
      _cameraIndex = 0;
    }

    final selected = cameras[_cameraIndex];

    final controller = CameraController(
      selected,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();

      final minZoom = await controller.getMinZoomLevel();
      final maxZoom = await controller.getMaxZoomLevel();

      await controller.setFlashMode(_flashMode);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _camera = controller;
        _minZoom = minZoom;
        _maxZoom = maxZoom;
        _zoom = math.max(minZoom, math.min(_zoom, maxZoom));
      });

      await controller.setZoomLevel(_zoom);
    } catch (e) {
      await controller.dispose();

      if (mounted) {
        _showMessage('Kamera gagal dibuka: $e');
      }
    }
  }

  Future<void> _reinitializeCurrentCamera() async {
    await _initializeCamera();
  }

  Future<void> _loadDatabase() async {
    final prefs = await SharedPreferences.getInstance();

    final raw = prefs.getString('excel_database');

    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);

      if (decoded is Map) {
        _barang = decoded.map(
          (key, value) => MapEntry(
            key.toString(),
            value.toString(),
          ),
        );
      }
    } catch (_) {
      _barang = {};
    }
  }

  Future<void> _saveDatabase() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'excel_database',
      jsonEncode(_barang),
    );
  }

  Future<void> _importExcel() async {
    setState(() {
      _excelMenuOpen = false;
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: false,
      );

      if (result == null ||
          result.files.single.path == null) {
        return;
      }

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

      for (int i = 1; i < rows.length; i++) {
        if (rows[i].length < 2) {
          continue;
        }

        final nomor =
            rows[i][0]?.value?.toString().trim() ?? '';

        final nama =
            rows[i][1]?.value?.toString().trim() ?? '';

        if (nomor.isNotEmpty && nama.isNotEmpty) {
          imported[nomor] = nama;
        }
      }

      if (imported.isEmpty) {
        _showMessage(
          'Tidak ditemukan data pada kolom A dan B.',
        );
        return;
      }

      _barang = imported;

      await _saveDatabase();

      if (mounted) {
        setState(() {});
      }

      _showMessage(
        'Berhasil import ${_barang.length} data barang.',
      );
    } catch (e) {
      _showMessage('Gagal membaca Excel: $e');
    }
  }

  Future<void> _resetDatabase() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF202124),
          title: const Text('Reset Excel'),
          content: const Text(
            'Daftar Excel yang tersimpan akan dihapus. '
            'Foto yang sudah ada tidak akan dihapus.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
              },
              child: const Text('BATAL'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context, true);
              },
              child: const Text('HAPUS'),
            ),
          ],
        );
      },
    );

    if (confirm != true) {
      return;
    }

    final prefs = await SharedPreferences.getInstance();

    await prefs.remove('excel_database');

    if (!mounted) {
      return;
    }

    setState(() {
      _barang.clear();
      _namaBarang = '';
      _nomorController.clear();
    });

    _showMessage('Data Excel berhasil dihapus.');
  }

  String _normalizeNumber(String value) {
    final cleaned = value.trim();

    if (cleaned.isEmpty) {
      return '';
    }

    final onlyDigits =
        cleaned.replaceAll(RegExp(r'[^0-9]'), '');

    if (onlyDigits.isEmpty) {
      return cleaned;
    }

    final normalized = onlyDigits.replaceFirst(
      RegExp(r'^0+(?=\d)'),
      '',
    );

    return normalized.isEmpty ? '0' : normalized;
  }

  String? _findBarang(String input) {
    final nomor = input.trim();

    if (nomor.isEmpty) {
      return null;
    }

    if (_barang.containsKey(nomor)) {
      return _barang[nomor];
    }

    final normalizedInput = _normalizeNumber(nomor);

    for (final entry in _barang.entries) {
      if (_normalizeNumber(entry.key) ==
          normalizedInput) {
        return entry.value;
      }
    }

    return null;
  }

  void _searchNumber(String value) {
    final nama = _findBarang(value);

    if (!mounted) {
      return;
    }

    setState(() {
      _namaBarang = nama ?? '';
    });
  }

  String _cleanFileName(String text) {
    var cleaned = text.replaceAll(
      RegExp(r'[\\/:*?"<>|]'),
      '',
    );

    cleaned = cleaned.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    cleaned = cleaned.replaceAll(
      RegExp(r'[. ]+$'),
      '',
    );

    return cleaned.isEmpty ? 'Barang' : cleaned;
  }

  Future<Directory> _photoDirectory() async {
    final directory = Directory(
      '/storage/emulated/0/Dokumentasi Barang Pecah',
    );

    if (!await directory.exists()) {
      await directory.create(
        recursive: true,
      );
    }

    return directory;
  }

  Future<File> _uniqueFile(
    Directory directory,
    String baseName,
  ) async {
    var candidate = File(
      '${directory.path}/$baseName.jpg',
    );

    if (!await candidate.exists()) {
      return candidate;
    }

    int index = 1;

    while (true) {
      candidate = File(
        '${directory.path}/${baseName}_$index.jpg',
      );

      if (!await candidate.exists()) {
        return candidate;
      }

      index++;
    }
  }

  Future<void> _takePhoto() async {
    if (_saving) {
      return;
    }

    final nomor = _nomorController.text.trim();

    if (nomor.isEmpty) {
      _openNumberEditor();
      _showMessage('Masukkan nomor barang terlebih dahulu.');
      return;
    }

    final nama = _findBarang(nomor);

    if (nama == null || nama.isEmpty) {
      _showMessage(
        'Nomor $nomor tidak ditemukan di Excel.',
      );
      return;
    }

    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      _showMessage('Kamera belum siap.');
      return;
    }

    setState(() {
      _saving = true;
    });

    try {
      if (_timerSeconds > 0) {
        await Future.delayed(
          Duration(seconds: _timerSeconds),
        );
      }

      final photo = await camera.takePicture();

      final directory = await _photoDirectory();

      final safeNumber = _cleanFileName(nomor);
      final safeName = _cleanFileName(nama);

      final baseName =
          '${safeNumber}_$safeName';

      final target = await _uniqueFile(
        directory,
        baseName,
      );

      await File(photo.path).copy(target.path);

      if (!mounted) {
        return;
      }

      setState(() {
        _saving = false;
      });

      _showPhotoSavedMessage(
        target.path,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }

      _showMessage(
        'Gagal menyimpan foto: $e',
      );
    }
  }

  void _showPhotoSavedMessage(String path) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Foto tersimpan\n$path',
          ),
        ),
      );
  }

  Future<void> _switchCamera() async {
    if (cameras.length < 2) {
      _showMessage(
        'HP ini hanya memiliki satu kamera.',
      );
      return;
    }

    final oldCamera = _camera;

    setState(() {
      _camera = null;
    });

    await oldCamera?.dispose();

    _cameraIndex++;

    if (_cameraIndex >= cameras.length) {
      _cameraIndex = 0;
    }

    await _initializeCamera();
  }

  Future<void> _changeFlash() async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    FlashMode next;

    switch (_flashMode) {
      case FlashMode.off:
        next = FlashMode.auto;
        break;

      case FlashMode.auto:
        next = FlashMode.always;
        break;

      case FlashMode.always:
        next = FlashMode.off;
        break;

      case FlashMode.torch:
        next = FlashMode.off;
        break;
    }

    try {
      await camera.setFlashMode(next);

      if (mounted) {
        setState(() {
          _flashMode = next;
        });
      }
    } catch (_) {
      _showMessage(
        'Flash tidak didukung kamera ini.',
      );
    }
  }

  Future<void> _setZoom(double value) async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    final safeZoom = value.clamp(
      _minZoom,
      _maxZoom,
    );

    try {
      await camera.setZoomLevel(
        safeZoom.toDouble(),
      );

      if (mounted) {
        setState(() {
          _zoom = safeZoom.toDouble();
        });
      }
    } catch (_) {}
  }

  void _openNumberEditor() {
    setState(() {
      _numberEditorOpen = true;
      _settingsOpen = false;
      _excelMenuOpen = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _nomorFocus.requestFocus();
      }
    });
  }

  void _closeFloatingMenus() {
    setState(() {
      _settingsOpen = false;
      _excelMenuOpen = false;
      _numberEditorOpen = false;
    });

    FocusScope.of(context).unfocus();
  }

  String _flashLabel() {
    switch (_flashMode) {
      case FlashMode.off:
        return 'OFF';

      case FlashMode.auto:
        return 'AUTO';

      case FlashMode.always:
        return 'ON';

      case FlashMode.torch:
        return 'TORCH';
    }
  }

  IconData _flashIcon() {
    switch (_flashMode) {
      case FlashMode.off:
        return Icons.flash_off;

      case FlashMode.auto:
        return Icons.flash_auto;

      case FlashMode.always:
        return Icons.flash_on;

      case FlashMode.torch:
        return Icons.flashlight_on;
    }
  }

  String _timerLabel() {
    if (_timerSeconds == 0) {
      return 'OFF';
    }

    return '${_timerSeconds}s';
  }

  void _cycleTimer() {
    int next;

    if (_timerSeconds == 0) {
      next = 3;
    } else if (_timerSeconds == 3) {
      next = 5;
    } else if (_timerSeconds == 5) {
      next = 10;
    } else {
      next = 0;
    }

    setState(() {
      _timerSeconds = next;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    _camera?.dispose();

    _nomorController.dispose();
    _nomorFocus.dispose();

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

    final cameraReady =
        _camera != null &&
        _camera!.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraPreview(cameraReady),
          if (_grid) _buildGrid(),
          _buildTopControls(),
          _buildBottomControls(),
          if (_settingsOpen) _buildSettingsPanel(),
          if (_excelMenuOpen) _buildExcelPanel(),
          if (_numberEditorOpen) _buildNumberPanel(),
          if (_saving) _buildSavingOverlay(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(bool cameraReady) {
    if (!cameraReady) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.no_photography_outlined,
                size: 58,
                color: Colors.white70,
              ),
              SizedBox(height: 12),
              Text(
                'Kamera belum tersedia',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      child: CameraPreview(_camera!),
    );
  }

  Widget _buildTopControls() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          12,
          8,
          12,
          0,
        ),
        child: Row(
          children: [
            _roundButton(
              icon: Icons.flash_auto,
              label: _flashLabel(),
              onTap: _changeFlash,
            ),
            const SizedBox(width: 8),
            _roundButton(
              icon: Icons.timer_outlined,
              label: _timerLabel(),
              onTap: _cycleTimer,
            ),
            const SizedBox(width: 8),
            _roundButton(
              icon: _grid
                  ? Icons.grid_on
                  : Icons.grid_off,
              label: 'GRID',
              active: _grid,
              onTap: () {
                setState(() {
                  _grid = !_grid;
                });
              },
            ),
            const Spacer(),
            _roundButton(
              icon: Icons.settings,
              label: 'SET',
              active: _settingsOpen,
              onTap: () {
                setState(() {
                  _settingsOpen = !_settingsOpen;
                  _excelMenuOpen = false;
                  _numberEditorOpen = false;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final nomor = _nomorController.text.trim();

    final displayName = nomor.isEmpty
        ? 'PILIH NOMOR'
        : _namaBarang.isEmpty
            ? 'NOMOR TIDAK DITEMUKAN'
            : '${_cleanFileName(nomor)}_${_cleanFileName(_namaBarang)}';

    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            14,
            0,
            14,
            18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildCurrentItem(displayName),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _bottomAction(
                    icon: Icons.table_view,
                    text: 'EXCEL',
                    onTap: () {
                      setState(() {
                        _excelMenuOpen =
                            !_excelMenuOpen;
                        _settingsOpen = false;
                        _numberEditorOpen = false;
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  _bottomAction(
                    icon: Icons.tag,
                    text: nomor.isEmpty
                        ? 'NOMOR'
                        : nomor,
                    onTap: _openNumberEditor,
                  ),
                  const Spacer(),
                  _shutterButton(),
                  const Spacer(),
                  _bottomAction(
                    icon: Icons.flip_camera_android,
                    text: 'CAM',
                    onTap: _switchCamera,
                  ),
                  const SizedBox(width: 8),
                  _bottomAction(
                    icon: Icons.folder_outlined,
                    text: 'FOLDER',
                    onTap: () {
                      _showMessage(
                        'Foto disimpan di:\n'
                        'Internal Storage/'
                        'Dokumentasi Barang Pecah',
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentItem(String displayName) {
    final found =
        _namaBarang.isNotEmpty;

    return GestureDetector(
      onTap: _openNumberEditor,
      child: Container(
        constraints: const BoxConstraints(
          minHeight: 54,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 10,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(
            alpha: 0.72,
          ),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: found
                ? Colors.greenAccent
                : Colors.white24,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              found
                  ? Icons.check_circle
                  : Icons.tag,
              color: found
                  ? Colors.greenAccent
                  : Colors.white70,
              size: 22,
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                displayName,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: found
                      ? Colors.white
                      : Colors.white70,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(
          horizontal: 10,
        ),
        decoration: BoxDecoration(
          color: active
              ? Colors.green.withValues(alpha: 0.85)
              : Colors.black.withValues(alpha: 0.62),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: Colors.white,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomAction({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: Colors.black.withValues(
            alpha: 0.68,
          ),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 21,
              color: Colors.white,
            ),
            const SizedBox(height: 2),
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shutterButton() {
    return GestureDetector(
      onTap: _saving ? null : _takePhoto,
      child: Container(
        width: 82,
        height: 82,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white,
            width: 4,
          ),
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: _saving
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.black,
                  ),
                )
              : const Icon(
                  Icons.camera_alt,
                  color: Colors.black,
                  size: 34,
                ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return IgnorePointer(
      child: CustomPaint(
        painter: _GridPainter(),
        size: Size.infinite,
      ),
    );
  }

  Widget _buildSettingsPanel() {
    return Positioned(
      top: 68,
      right: 12,
      child: SafeArea(
        child: Container(
          width: 290,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF171717)
                .withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white24,
            ),
            boxShadow: const [
              BoxShadow(
                blurRadius: 20,
                color: Colors.black54,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              const Text(
                'PENGATURAN KAMERA',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 14),
              _settingRow(
                icon: _flashIcon(),
                title: 'Flash',
                value: _flashLabel(),
                onTap: _changeFlash,
              ),
              _settingRow(
                icon: Icons.timer_outlined,
                title: 'Timer',
                value: _timerLabel(),
                onTap: _cycleTimer,
              ),
              _settingRow(
                icon: Icons.grid_3x3,
                title: 'Grid',
                value: _grid ? 'ON' : 'OFF',
                onTap: () {
                  setState(() {
                    _grid = !_grid;
                  });
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'ZOOM',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white54,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      min: _minZoom,
                      max: _maxZoom <= _minZoom
                          ? _minZoom + 1
                          : _maxZoom,
                      value: _zoom.clamp(
                        _minZoom,
                        _maxZoom <= _minZoom
                            ? _minZoom + 1
                            : _maxZoom,
                      ),
                      onChanged: _setZoom,
                    ),
                  ),
                  Text(
                    '${_zoom.toStringAsFixed(1)}x',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              const Divider(
                color: Colors.white12,
              ),
              _settingRow(
                icon: Icons.folder_outlined,
                title: 'Penyimpanan',
                value: 'Dokumentasi Barang Pecah',
                onTap: () {
                  _showMessage(
                    'Internal Storage/'
                    'Dokumentasi Barang Pecah',
                  );
                },
              ),
              _settingRow(
                icon: Icons.delete_outline,
                title: 'Reset Excel',
                value: '${_barang.length} data',
                onTap: _resetDatabase,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingRow({
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          vertical: 9,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 21,
              color: Colors.white70,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExcelPanel() {
    return Positioned(
      left: 12,
      bottom: 95,
      child: SafeArea(
        child: Container(
          width: 250,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF171717)
                .withValues(alpha: 0.97),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: Colors.white24,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.table_view,
                    color: Colors.greenAccent,
                  ),
                  SizedBox(width: 10),
                  Text(
                    'DATA EXCEL',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _importExcel,
                  icon: const Icon(
                    Icons.upload_file,
                  ),
                  label: const Text(
                    'IMPORT EXCEL',
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${_barang.length} data tersimpan',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 5),
              TextButton(
                onPressed: _resetDatabase,
                child: const Text(
                  'Reset data Excel',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNumberPanel() {
    final found =
        _namaBarang.isNotEmpty;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(
          alpha: 0.65,
        ),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: const Color(0xFF1C1C1C),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white24,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.tag,
                  size: 34,
                  color: Colors.greenAccent,
                ),
                const SizedBox(height: 8),
                const Text(
                  'NOMOR BARANG',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: _nomorController,
                  focusNode: _nomorFocus,
                  autofocus: true,
                  keyboardType:
                      TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter
                        .digitsOnly,
                  ],
                  onChanged: _searchNumber,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.bold,
                  ),
                  decoration:
                      InputDecoration(
                    hintText: '01',
                    filled: true,
                    fillColor:
                        Colors.white10,
                    border: OutlineInputBorder(
                      borderRadius:
                          BorderRadius.circular(
                        16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                AnimatedSwitcher(
                  duration:
                      const Duration(
                    milliseconds: 150,
                  ),
                  child: found
                      ? Text(
                          _namaBarang,
                          key: const ValueKey(
                            'found',
                          ),
                          textAlign:
                              TextAlign.center,
                          style:
                              const TextStyle(
                            color:
                                Colors.greenAccent,
                            fontSize: 18,
                            fontWeight:
                                FontWeight.bold,
                          ),
                        )
                      : _nomorController.text
                              .isNotEmpty
                          ? const Text(
                              'Nomor tidak ditemukan di Excel',
                              key: ValueKey(
                                'notfound',
                              ),
                              textAlign:
                                  TextAlign.center,
                              style: TextStyle(
                                color:
                                    Colors.redAccent,
                                fontWeight:
                                    FontWeight.bold,
                              ),
                            )
                          : const Text(
                              'Masukkan nomor dari Excel',
                              key: ValueKey(
                                'empty',
                              ),
                              style:
                                  TextStyle(
                                color:
                                    Colors.white54,
                              ),
                            ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed:
                            _closeFloatingMenus,
                        child: const Text(
                          'BATAL',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () {
                          if (_namaBarang
                              .isEmpty) {
                            _showMessage(
                              'Nomor tidak ditemukan.',
                            );
                            return;
                          }

                          setState(() {
                            _numberEditorOpen =
                                false;
                          });

                          FocusScope.of(
                            context,
                          ).unfocus();
                        },
                        child: const Text(
                          'PILIH',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSavingOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Container(
          color: Colors.black.withValues(
            alpha: 0.25,
          ),
          child: const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 52,
                  height: 52,
                  child:
                      CircularProgressIndicator(
                    strokeWidth: 4,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'MENYIMPAN FOTO...',
                  style: TextStyle(
                    fontWeight:
                        FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint = Paint()
      ..color = Colors.white.withValues(
        alpha: 0.35,
      )
      ..strokeWidth = 1;

    final thirdWidth = size.width / 3;
    final thirdHeight = size.height / 3;

    canvas.drawLine(
      Offset(thirdWidth, 0),
      Offset(thirdWidth, size.height),
      paint,
    );

    canvas.drawLine(
      Offset(thirdWidth * 2, 0),
      Offset(
        thirdWidth * 2,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(0, thirdHeight),
      Offset(size.width, thirdHeight),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        thirdHeight * 2,
      ),
      Offset(
        size.width,
        thirdHeight * 2,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(
    covariant CustomPainter oldDelegate,
  ) {
    return false;
  }
}
