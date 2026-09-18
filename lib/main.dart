import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:excel/excel.dart' as excel;
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
  bool _statusPanelOpen = false;

  FlashMode _flashMode = FlashMode.off;

  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;

  int _timerSeconds = 0;

  int _cameraIndex = 0;

  ResolutionPreset _resolutionPreset =
      ResolutionPreset.high;

  String _aspectRatio = '4:3';

  String _storagePath =
      '/storage/emulated/0/Dokumentasi Barang Pecah';

  Set<String> _documentedNumbers = <String>{};

  String _lastPhotoPath = '';

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);

    _initialize();
  }

  @override
  void didChangeAppLifecycleState(
    AppLifecycleState state,
  ) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _disposeCameraOnly();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _loadDatabase();
    await _loadSettings();
    await _scanDocumentedPhotos();
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

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    final resolution =
        prefs.getString('camera_resolution');

    switch (resolution) {
      case 'low':
        _resolutionPreset = ResolutionPreset.low;
        break;
      case 'medium':
        _resolutionPreset = ResolutionPreset.medium;
        break;
      case 'veryHigh':
        _resolutionPreset = ResolutionPreset.veryHigh;
        break;
      case 'max':
        _resolutionPreset = ResolutionPreset.max;
        break;
      case 'high':
      default:
        _resolutionPreset = ResolutionPreset.high;
    }

    _aspectRatio =
        prefs.getString('camera_aspect_ratio') ?? '4:3';
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'camera_resolution',
      _resolutionName(_resolutionPreset),
    );

    await prefs.setString(
      'camera_aspect_ratio',
      _aspectRatio,
    );
  }

  String _resolutionName(ResolutionPreset preset) {
    switch (preset) {
      case ResolutionPreset.low:
        return 'low';
      case ResolutionPreset.medium:
        return 'medium';
      case ResolutionPreset.high:
        return 'high';
      case ResolutionPreset.veryHigh:
        return 'veryHigh';
      case ResolutionPreset.ultraHigh:
        return 'ultraHigh';
      case ResolutionPreset.max:
        return 'max';
    }
  }

  String _resolutionLabel(
    ResolutionPreset preset,
  ) {
    switch (preset) {
      case ResolutionPreset.low:
        return 'Rendah';
      case ResolutionPreset.medium:
        return 'Sedang';
      case ResolutionPreset.high:
        return 'Tinggi';
      case ResolutionPreset.veryHigh:
        return 'Sangat Tinggi';
      case ResolutionPreset.ultraHigh:
        return 'Ultra';
      case ResolutionPreset.max:
        return 'Maksimal';
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
      _resolutionPreset,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await controller.initialize();

      final minZoom =
          await controller.getMinZoomLevel();

      final maxZoom =
          await controller.getMaxZoomLevel();

      try {
        await controller.setFlashMode(_flashMode);
      } catch (_) {}

      if (!mounted) {
        await controller.dispose();
        return;
      }

      final oldCamera = _camera;

      setState(() {
        _camera = controller;
        _minZoom = minZoom;
        _maxZoom = maxZoom;

        _zoom = math.max(
          minZoom,
          math.min(_zoom, maxZoom),
        );
      });

      await oldCamera?.dispose();

      try {
        await controller.setZoomLevel(_zoom);
      } catch (_) {}
    } catch (e) {
      await controller.dispose();

      if (mounted) {
        _showMessage(
          'Kamera gagal dibuka: $e',
        );
      }
    }
  }

  Future<void> _disposeCameraOnly() async {
    final camera = _camera;

    _camera = null;

    await camera?.dispose();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadDatabase() async {
    final prefs =
        await SharedPreferences.getInstance();

    final raw =
        prefs.getString('excel_database');

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
    final prefs =
        await SharedPreferences.getInstance();

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
      final result =
          await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: false,
      );

      if (result == null ||
          result.files.single.path == null) {
        return;
      }

      final file =
          File(result.files.single.path!);

      final bytes =
          await file.readAsBytes();

      final workbook =
          excel.Excel.decodeBytes(bytes);

      if (workbook.tables.isEmpty) {
        _showMessage(
          'Excel tidak memiliki sheet.',
        );
        return;
      }

      final sheet =
          workbook.tables.values.first;

      final rows = sheet.rows;

      if (rows.isEmpty) {
        _showMessage(
          'Excel tidak memiliki data.',
        );
        return;
      }

      final Map<String, String> imported =
          {};

      for (int i = 1; i < rows.length; i++) {
        if (rows[i].length < 2) {
          continue;
        }

        final nomor =
            rows[i][0]?.value
                    ?.toString()
                    .trim() ??
                '';

        final nama =
            rows[i][1]?.value
                    ?.toString()
                    .trim() ??
                '';

        if (nomor.isNotEmpty &&
            nama.isNotEmpty) {
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
      await _scanDocumentedPhotos();

      if (mounted) {
        setState(() {
          _namaBarang = '';
          _nomorController.clear();
        });
      }

      _showMessage(
        'Berhasil import ${_barang.length} data barang.',
      );
    } catch (e) {
      _showMessage(
        'Gagal membaca Excel: $e',
      );
    }
  }

  Future<void> _resetDatabase() async {
    final confirm =
        await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF202124),
          title:
              const Text('Reset Excel'),
          content: const Text(
            'Daftar Excel yang tersimpan '
            'akan dihapus. Foto yang sudah '
            'ada tidak akan dihapus.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  false,
                );
              },
              child:
                  const Text('BATAL'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  true,
                );
              },
              child:
                  const Text('HAPUS'),
            ),
          ],
        );
      },
    );

    if (confirm != true) {
      return;
    }

    final prefs =
        await SharedPreferences.getInstance();

    await prefs.remove(
      'excel_database',
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _barang.clear();
      _namaBarang = '';
      _nomorController.clear();
    });

    _showMessage(
      'Data Excel berhasil dihapus.',
    );
  }

  String _normalizeNumber(String value) {
    final cleaned = value.trim();

    if (cleaned.isEmpty) {
      return '';
    }

    final onlyDigits =
        cleaned.replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );

    if (onlyDigits.isEmpty) {
      return cleaned;
    }

    final normalized =
        onlyDigits.replaceFirst(
      RegExp(r'^0+(?=\d)'),
      '',
    );

    return normalized.isEmpty
        ? '0'
        : normalized;
  }

  String? _findBarang(
    String input,
  ) {
    final nomor = input.trim();

    if (nomor.isEmpty) {
      return null;
    }

    if (_barang.containsKey(nomor)) {
      return _barang[nomor];
    }

    final normalizedInput =
        _normalizeNumber(nomor);

    for (final entry
        in _barang.entries) {
      if (_normalizeNumber(
            entry.key,
          ) ==
          normalizedInput) {
        return entry.value;
      }
    }

    return null;
  }

  String? _findOriginalNumber(
    String input,
  ) {
    final nomor = input.trim();

    if (_barang.containsKey(nomor)) {
      return nomor;
    }

    final normalized =
        _normalizeNumber(nomor);

    for (final key
        in _barang.keys) {
      if (_normalizeNumber(key) ==
          normalized) {
        return key;
      }
    }

    return null;
  }

  void _searchNumber(
    String value,
  ) {
    final nama =
        _findBarang(value);

    if (!mounted) {
      return;
    }

    setState(() {
      _namaBarang =
          nama ?? '';
    });
  }

  String _cleanFileName(
    String text,
  ) {
    var cleaned =
        text.replaceAll(
      RegExp(
        r'[\\/:*?"<>|]',
      ),
      '',
    );

    cleaned =
        cleaned.replaceAll(
      RegExp(r'\s+'),
      ' ',
    );

    cleaned =
        cleaned.replaceAll(
      RegExp(r'[. ]+$'),
      '',
    );

    return cleaned.isEmpty
        ? 'Barang'
        : cleaned;
  }

  Future<Directory>
      _photoDirectory() async {
    final directory =
        Directory(_storagePath);

    if (!await directory.exists()) {
      await directory.create(
        recursive: true,
      );
    }

    return directory;
  }

  Future<void>
      _scanDocumentedPhotos() async {
    try {
      final directory =
          await _photoDirectory();

      final files =
          await directory.list().toList();

      final Set<String> found =
          <String>{};

      for (final entity in files) {
        if (entity is! File) {
          continue;
        }

        final name =
            entity.path
                .split('/')
                .last;

        if (!name
            .toLowerCase()
            .endsWith('.jpg')) {
          continue;
        }

        final match =
            RegExp(
          r'^([^_]+)_.+\.jpg$',
          caseSensitive: false,
        ).firstMatch(name);

        if (match != null) {
          found.add(
            _normalizeNumber(
              match.group(1) ?? '',
            ),
          );
        }
      }

      if (mounted) {
        setState(() {
          _documentedNumbers =
              found;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _documentedNumbers.clear();
        });
      }
    }
  }

  bool _isDocumented(
    String nomor,
  ) {
    return _documentedNumbers.contains(
      _normalizeNumber(nomor),
    );
  }

  int get _totalItems {
    return _barang.length;
  }

  int get _documentedCount {
    int count = 0;

    for (final key
        in _barang.keys) {
      if (_isDocumented(key)) {
        count++;
      }
    }

    return count;
  }

  int get _remainingCount {
    return math.max(
      0,
      _totalItems - _documentedCount,
    );
  }

  double get _progress {
    if (_totalItems == 0) {
      return 0;
    }

    return _documentedCount /
        _totalItems;
  }

  List<String> get _orderedNumbers {
    return _barang.keys.toList();
  }

  int _currentIndex() {
    final original =
        _findOriginalNumber(
      _nomorController.text,
    );

    if (original == null) {
      return -1;
    }

    return _orderedNumbers
        .indexOf(original);
  }

  void _selectNumber(
    String nomor,
  ) {
    _nomorController.text =
        nomor;

    _searchNumber(nomor);

    setState(() {
      _statusPanelOpen = false;
      _numberEditorOpen = false;
    });

    FocusScope.of(context)
        .unfocus();
  }

  void _goPrevious() {
    final numbers =
        _orderedNumbers;

    if (numbers.isEmpty) {
      return;
    }

    final current =
        _currentIndex();

    int target;

    if (current <= 0) {
      target =
          numbers.length - 1;
    } else {
      target = current - 1;
    }

    _selectNumber(
      numbers[target],
    );
  }

  void _goNext() {
    final numbers =
        _orderedNumbers;

    if (numbers.isEmpty) {
      return;
    }

    final current =
        _currentIndex();

    int target;

    if (current < 0 ||
        current >=
            numbers.length - 1) {
      target = 0;
    } else {
      target = current + 1;
    }

    _selectNumber(
      numbers[target],
    );
  }

  Future<File> _uniqueFile(
    Directory directory,
    String baseName,
  ) async {
    var candidate =
        File(
      '${directory.path}/$baseName.jpg',
    );

    if (!await candidate.exists()) {
      return candidate;
    }

    int index = 1;

    while (true) {
      candidate =
          File(
        '${directory.path}/'
        '${baseName}_$index.jpg',
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

    final nomor =
        _nomorController.text.trim();

    if (nomor.isEmpty) {
      _openNumberEditor();

      _showMessage(
        'Masukkan nomor barang terlebih dahulu.',
      );

      return;
    }

    final nama =
        _findBarang(nomor);

    if (nama == null ||
        nama.isEmpty) {
      _showMessage(
        'Nomor $nomor tidak ditemukan di Excel.',
      );

      return;
    }

    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      _showMessage(
        'Kamera belum siap.',
      );

      return;
    }

    if (_isDocumented(nomor)) {
      final ulang =
          await _confirmRetake(nomor);

      if (ulang != true) {
        return;
      }
    }

    setState(() {
      _saving = true;
    });

    try {
      if (_timerSeconds > 0) {
        await _runCountdown();
      }

      if (!camera.value.isInitialized) {
        throw Exception(
          'Kamera tidak aktif.',
        );
      }

      final photo =
          await camera.takePicture();

      final directory =
          await _photoDirectory();

      final safeNumber =
          _cleanFileName(nomor);

      final safeName =
          _cleanFileName(nama);

      final baseName =
          '${safeNumber}_$safeName';

      final target =
          await _uniqueFile(
        directory,
        baseName,
      );

      await File(photo.path)
          .copy(target.path);

      if (!mounted) {
        return;
      }

      setState(() {
        _lastPhotoPath =
            target.path;

        _documentedNumbers.add(
          _normalizeNumber(nomor),
        );

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

  Future<void> _runCountdown() async {
    for (int i = _timerSeconds;
        i > 0;
        i--) {
      if (!mounted) {
        return;
      }

      setState(() {});

      await Future.delayed(
        const Duration(seconds: 1),
      );
    }
  }

  Future<bool?> _confirmRetake(
    String nomor,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor:
              const Color(0xFF202124),
          title: const Text(
            'Sudah didokumentasikan',
          ),
          content: Text(
            'Nomor $nomor sudah memiliki '
            'foto.\n\nApakah ingin mengambil '
            'foto lagi?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  false,
                );
              },
              child:
                  const Text('BATAL'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(
                  context,
                  true,
                );
              },
              child:
                  const Text('FOTO ULANG'),
            ),
          ],
        );
      },
    );
  }

  void _showPhotoSavedMessage(
    String path,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration:
              const Duration(seconds: 4),
          behavior:
              SnackBarBehavior.floating,
          content: Text(
            'Foto tersimpan\n'
            '${path.split('/').last}',
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

    final oldCamera =
        _camera;

    setState(() {
      _camera = null;
    });

    await oldCamera?.dispose();

    _cameraIndex++;

    if (_cameraIndex >=
        cameras.length) {
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

  Future<void> _setZoom(
    double value,
  ) async {
    final camera = _camera;

    if (camera == null ||
        !camera.value.isInitialized) {
      return;
    }

    final safeZoom =
        value.clamp(
      _minZoom,
      _maxZoom,
    );

    try {
      await camera.setZoomLevel(
        safeZoom.toDouble(),
      );

      if (mounted) {
        setState(() {
          _zoom =
              safeZoom.toDouble();
        });
      }
    } catch (_) {}
  }

  Future<void> _changeResolution(
    ResolutionPreset preset,
  ) async {
    if (_resolutionPreset ==
        preset) {
      return;
    }

    setState(() {
      _resolutionPreset =
          preset;
    });

    await _saveSettings();

    await _disposeCameraOnly();
    await _initializeCamera();

    if (mounted) {
      _showMessage(
        'Kualitas foto: '
        '${_resolutionLabel(preset)}',
      );
    }
  }

  Future<void> _changeAspectRatio(
    String ratio,
  ) async {
    setState(() {
      _aspectRatio = ratio;
    });

    await _saveSettings();

    if (mounted) {
      _showMessage(
        'Tampilan kamera: $ratio',
      );
    }
  }

  void _openNumberEditor() {
    setState(() {
      _numberEditorOpen = true;
      _settingsOpen = false;
      _excelMenuOpen = false;
      _statusPanelOpen = false;
    });

    WidgetsBinding.instance
        .addPostFrameCallback((_) {
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
      _statusPanelOpen = false;
    });

    FocusScope.of(context)
        .unfocus();
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

  Future<void> _exportCsv() async {
    if (_barang.isEmpty) {
      _showMessage(
        'Belum ada data Excel.',
      );
      return;
    }

    try {
      final directory =
          await _photoDirectory();

      final file =
          File(
        '${directory.path}/'
        'Laporan Dokumentasi Barang.csv',
      );

      final buffer =
          StringBuffer();

      buffer.writeln(
        'No,Nama Barang,Status,File Foto',
      );

      for (final entry
          in _barang.entries) {
        final nomor =
            entry.key;

        final nama =
            entry.value;

        final status =
            _isDocumented(nomor)
                ? 'SUDAH'
                : 'BELUM';

        final foto =
            _isDocumented(nomor)
                ? '${_cleanFileName(nomor)}_'
                    '${_cleanFileName(nama)}.jpg'
                : '';

        buffer.writeln(
          '${_csv(nomor)},'
          '${_csv(nama)},'
          '${_csv(status)},'
          '${_csv(foto)}',
        );
      }

      await file.writeAsString(
        buffer.toString(),
        flush: true,
      );

      _showMessage(
        'Laporan berhasil dibuat:\n'
        '${file.path}',
      );
    } catch (e) {
      _showMessage(
        'Gagal membuat laporan: $e',
      );
    }
  }

  String _csv(String value) {
    return '"${value.replaceAll('"', '""')}"';
  }

  @override
  void dispose() {
    WidgetsBinding.instance
        .removeObserver(this);

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
          child:
              CircularProgressIndicator(),
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
          _buildCameraPreview(
            cameraReady,
          ),
          if (_grid)
            _buildGrid(),

          _buildTopControls(),
          _buildProgressBar(),
          _buildBottomControls(),

          if (_settingsOpen)
            _buildSettingsPanel(),

          if (_excelMenuOpen)
            _buildExcelPanel(),

          if (_statusPanelOpen)
            _buildStatusPanel(),

          if (_numberEditorOpen)
            _buildNumberPanel(),

          if (_saving)
            _buildSavingOverlay(),
        ],
      ),
    );
  }

  Widget _buildCameraPreview(
    bool cameraReady,
  ) {
    if (!cameraReady) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              Icon(
                Icons
                    .no_photography_outlined,
                size: 58,
                color:
                    Colors.white70,
              ),
              SizedBox(height: 12),
              Text(
                'Kamera belum tersedia',
                style: TextStyle(
                  color:
                      Colors.white70,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final preview =
        CameraPreview(_camera!);

    return Center(
      child: AspectRatio(
        aspectRatio:
            _aspectRatio == '16:9'
                ? 16 / 9
                : 4 / 3,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width:
                  _camera!
                      .value
                      .previewSize
                      ?.height ??
                  1,
              height:
                  _camera!
                      .value
                      .previewSize
                      ?.width ??
                  1,
              child: preview,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopControls() {
    return SafeArea(
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(
          8,
          6,
          8,
          0,
        ),
        child: LayoutBuilder(
          builder:
              (context, constraints) {
            final width =
                constraints.maxWidth;

            final compact =
                width < 380;

            return Row(
              children: [
                Expanded(
                  child:
                      _topControl(
                    icon:
                        _flashIcon(),
                    label:
                        _flashLabel(),
                    onTap:
                        _changeFlash,
                    compact:
                        compact,
                  ),
                ),
                SizedBox(
                  width:
                      compact ? 4 : 6,
                ),
                Expanded(
                  child:
                      _topControl(
                    icon:
                        Icons.timer_outlined,
                    label:
                        _timerLabel(),
                    onTap:
                        _cycleTimer,
                    compact:
                        compact,
                  ),
                ),
                SizedBox(
                  width:
                      compact ? 4 : 6,
                ),
                Expanded(
                  child:
                      _topControl(
                    icon: _grid
                        ? Icons.grid_on
                        : Icons.grid_off,
                    label:
                        _grid
                            ? 'ON'
                            : 'GRID',
                    active:
                        _grid,
                    onTap: () {
                      setState(() {
                        _grid =
                            !_grid;
                      });
                    },
                    compact:
                        compact,
                  ),
                ),
                SizedBox(
                  width:
                      compact ? 4 : 6,
                ),
                Expanded(
                  child:
                      _topControl(
                    icon:
                        Icons.settings,
                    label: 'SET',
                    active:
                        _settingsOpen,
                    onTap: () {
                      setState(() {
                        _settingsOpen =
                            !_settingsOpen;
                        _excelMenuOpen =
                            false;
                        _numberEditorOpen =
                            false;
                        _statusPanelOpen =
                            false;
                      });
                    },
                    compact:
                        compact,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _topControl({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    bool compact = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height:
            compact ? 42 : 46,
        decoration:
            BoxDecoration(
          color: active
              ? Colors.green
                  .withValues(
                  alpha: 0.88,
                )
              : Colors.black
                  .withValues(
                  alpha: 0.62,
                ),
          borderRadius:
              BorderRadius.circular(
            14,
          ),
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .center,
          children: [
            Icon(
              icon,
              size:
                  compact ? 18 : 20,
            ),
            const SizedBox(
              width: 4,
            ),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow:
                    TextOverflow
                        .ellipsis,
                style:
                    TextStyle(
                  fontSize:
                      compact ? 9 : 10,
                  fontWeight:
                      FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    return SafeArea(
      child: Align(
        alignment:
            Alignment.topCenter,
        child: Padding(
          padding:
              const EdgeInsets.only(
            top: 58,
            left: 12,
            right: 12,
          ),
          child: Container(
            padding:
                const EdgeInsets
                    .symmetric(
              horizontal: 12,
              vertical: 7,
            ),
            decoration:
                BoxDecoration(
              color: Colors.black
                  .withValues(
                alpha: 0.62,
              ),
              borderRadius:
                  BorderRadius.circular(
                16,
              ),
            ),
            child: Row(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                const Icon(
                  Icons
                      .photo_camera_outlined,
                  size: 16,
                ),
                const SizedBox(
                  width: 7,
                ),
                Text(
                  '$_documentedCount / '
                  '$_totalItems',
                  style:
                      const TextStyle(
                    fontSize: 13,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                if (_totalItems >
                    0) ...[
                  const SizedBox(
                    width: 8,
                  ),
                  Text(
                    '${(_progress * 100).round()}%',
                    style:
                        const TextStyle(
                      color: Colors
                          .greenAccent,
                      fontSize: 12,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final nomor =
        _nomorController.text
            .trim();

    final found =
        _namaBarang.isNotEmpty;

    return SafeArea(
      child: Align(
        alignment:
            Alignment.bottomCenter,
        child: Padding(
          padding:
              const EdgeInsets
                  .fromLTRB(
            8,
            0,
            8,
            12,
          ),
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              _buildCurrentItem(),
              const SizedBox(
                height: 8,
              ),
              _buildNavigation(),
              const SizedBox(
                height: 10,
              ),
              LayoutBuilder(
                builder:
                    (context,
                        constraints) {
                  return Row(
                    children: [
                      Expanded(
                        child:
                            _bottomAction(
                          icon:
                              Icons.table_view,
                          text:
                              'EXCEL',
                          onTap: () {
                            setState(() {
                              _excelMenuOpen =
                                  !_excelMenuOpen;
                              _settingsOpen =
                                  false;
                              _numberEditorOpen =
                                  false;
                              _statusPanelOpen =
                                  false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(
                        width: 5,
                      ),
                      Expanded(
                        child:
                            _bottomAction(
                          icon:
                              Icons.list_alt,
                          text:
                              'STATUS',
                          onTap: () {
                            setState(() {
                              _statusPanelOpen =
                                  !_statusPanelOpen;
                              _excelMenuOpen =
                                  false;
                              _settingsOpen =
                                  false;
                              _numberEditorOpen =
                                  false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(
                        width: 8,
                      ),
                      _shutterButton(),
                      const SizedBox(
                        width: 8,
                      ),
                      Expanded(
                        child:
                            _bottomAction(
                          icon:
                              Icons.tag,
                          text:
                              nomor.isEmpty
                                  ? 'NOMOR'
                                  : nomor,
                          onTap:
                              _openNumberEditor,
                        ),
                      ),
                      const SizedBox(
                        width: 5,
                      ),
                      Expanded(
                        child:
                            _bottomAction(
                          icon:
                              Icons
                                  .flip_camera_android,
                          text:
                              'CAM',
                          onTap:
                              _switchCamera,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCurrentItem() {
    final nomor =
        _nomorController.text
            .trim();

    final found =
        _namaBarang.isNotEmpty;

    final documented =
        nomor.isNotEmpty &&
            _isDocumented(nomor);

    return GestureDetector(
      onTap:
          _openNumberEditor,
      child: Container(
        width:
            double.infinity,
        constraints:
            const BoxConstraints(
          minHeight: 54,
        ),
        padding:
            const EdgeInsets
                .symmetric(
          horizontal: 14,
          vertical: 8,
        ),
        decoration:
            BoxDecoration(
          color: Colors.black
              .withValues(
            alpha: 0.72,
          ),
          borderRadius:
              BorderRadius.circular(
            17,
          ),
          border: Border.all(
            color: documented
                ? Colors.orangeAccent
                : found
                    ? Colors
                        .greenAccent
                    : Colors
                        .white24,
          ),
        ),
        child: Row(
          children: [
            Icon(
              documented
                  ? Icons
                      .check_circle
                  : found
                      ? Icons
                          .verified
                      : Icons.tag,
              color: documented
                  ? Colors
                      .orangeAccent
                  : found
                      ? Colors
                          .greenAccent
                      : Colors
                          .white70,
              size: 22,
            ),
            const SizedBox(
              width: 9,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment
                        .start,
                children: [
                  Text(
                    nomor.isEmpty
                        ? 'PILIH NOMOR BARANG'
                        : nomor,
                    style:
                        const TextStyle(
                      fontSize: 12,
                      color:
                          Colors.white54,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                  const SizedBox(
                    height: 2,
                  ),
                  Text(
                    found
                        ? _namaBarang
                        : nomor.isEmpty
                            ? 'Ketik nomor dari Excel'
                            : 'Nomor tidak ditemukan',
                    maxLines: 2,
                    overflow:
                        TextOverflow
                            .ellipsis,
                    style:
                        TextStyle(
                      color: found
                          ? Colors.white
                          : Colors
                              .white70,
                      fontSize: 15,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            if (documented)
              const Padding(
                padding:
                    EdgeInsets.only(
                  left: 8,
                ),
                child: Text(
                  'SUDAH',
                  style:
                      TextStyle(
                    color: Colors
                        .orangeAccent,
                    fontSize: 10,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigation() {
    return Row(
      children: [
        Expanded(
          child:
              _navigationButton(
            icon:
                Icons.chevron_left,
            text:
                'SEBELUMNYA',
            onTap:
                _goPrevious,
          ),
        ),
        const SizedBox(
          width: 8,
        ),
        Expanded(
          child:
              _navigationButton(
            icon:
                Icons.chevron_right,
            text:
                'BERIKUTNYA',
            iconRight: true,
            onTap:
                _goNext,
          ),
        ),
      ],
    );
  }

  Widget _navigationButton({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
    bool iconRight = false,
  }) {
    final children = [
      if (!iconRight)
        Icon(
          icon,
          size: 20,
        ),
      const SizedBox(
        width: 4,
      ),
      Text(
        text,
        style:
            const TextStyle(
          fontSize: 10,
          fontWeight:
              FontWeight.bold,
        ),
      ),
      if (iconRight)
        const SizedBox(
          width: 4,
        ),
      if (iconRight)
        Icon(
          icon,
          size: 20,
        ),
    ];

    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 38,
        decoration:
            BoxDecoration(
          color: Colors.black
              .withValues(
            alpha: 0.60,
          ),
          borderRadius:
              BorderRadius.circular(
            14,
          ),
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Row(
          mainAxisAlignment:
              MainAxisAlignment
                  .center,
          children: children,
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
        height: 58,
        decoration:
            BoxDecoration(
          color: Colors.black
              .withValues(
            alpha: 0.68,
          ),
          shape: BoxShape.circle,
          border: Border.all(
            color: Colors.white24,
          ),
        ),
        child: Column(
          mainAxisAlignment:
              MainAxisAlignment
                  .center,
          children: [
            Icon(
              icon,
              size: 21,
            ),
            const SizedBox(
              height: 2,
            ),
            Text(
              text,
              maxLines: 1,
              overflow:
                  TextOverflow
                      .ellipsis,
              style:
                  const TextStyle(
                fontSize: 8,
                fontWeight:
                    FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shutterButton() {
    return GestureDetector(
      onTap:
          _saving
              ? null
              : _takePhoto,
      child: Container(
        width: 78,
        height: 78,
        padding:
            const EdgeInsets.all(
          5,
        ),
        decoration:
            BoxDecoration(
          shape:
              BoxShape.circle,
          border:
              Border.all(
            color:
                Colors.white,
            width: 4,
          ),
        ),
        child: Container(
          decoration:
              const BoxDecoration(
            color:
                Colors.white,
            shape:
                BoxShape.circle,
          ),
          child: _saving
              ? const Padding(
                  padding:
                      EdgeInsets.all(
                    20,
                  ),
                  child:
                      CircularProgressIndicator(
                    strokeWidth: 3,
                    color:
                        Colors.black,
                  ),
                )
              : const Icon(
                  Icons
                      .camera_alt,
                  color:
                      Colors.black,
                  size: 32,
                ),
        ),
      ),
    );
  }

  Widget _buildGrid() {
    return IgnorePointer(
      child: CustomPaint(
        painter:
            _GridPainter(),
        size:
            Size.infinite,
      ),
    );
  }

  Widget _buildSettingsPanel() {
    return Positioned(
      top: 58,
      left: 10,
      right: 10,
      child: SafeArea(
        child: Container(
          constraints:
              const BoxConstraints(
            maxHeight: 520,
          ),
          padding:
              const EdgeInsets.all(
            14,
          ),
          decoration:
              BoxDecoration(
            color: const Color(
              0xFF171717,
            ).withValues(
              alpha: 0.97,
            ),
            borderRadius:
                BorderRadius.circular(
              20,
            ),
            border: Border.all(
              color:
                  Colors.white24,
            ),
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment
                      .start,
              children: [
                const Text(
                  'PENGATURAN KAMERA',
                  style:
                      TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const SizedBox(
                  height: 12,
                ),
                _settingRow(
                  icon:
                      _flashIcon(),
                  title:
                      'Flash',
                  value:
                      _flashLabel(),
                  onTap:
                      _changeFlash,
                ),
                _settingRow(
                  icon:
                      Icons.timer_outlined,
                  title:
                      'Timer',
                  value:
                      _timerLabel(),
                  onTap:
                      _cycleTimer,
                ),
                _settingRow(
                  icon:
                      Icons.grid_3x3,
                  title:
                      'Grid',
                  value:
                      _grid
                          ? 'ON'
                          : 'OFF',
                  onTap: () {
                    setState(() {
                      _grid =
                          !_grid;
                    });
                  },
                ),
                const Divider(
                  color:
                      Colors.white12,
                ),
                const Text(
                  'RASIO TAMPILAN',
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 11,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const SizedBox(
                  height: 6,
                ),
                Row(
                  children: [
                    Expanded(
                      child:
                          _choiceButton(
                        text:
                            '4 : 3',
                        selected:
                            _aspectRatio ==
                                '4:3',
                        onTap: () =>
                            _changeAspectRatio(
                          '4:3',
                        ),
                      ),
                    ),
                    const SizedBox(
                      width: 8,
                    ),
                    Expanded(
                      child:
                          _choiceButton(
                        text:
                            '16 : 9',
                        selected:
                            _aspectRatio ==
                                '16:9',
                        onTap: () =>
                            _changeAspectRatio(
                          '16:9',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(
                  height: 12,
                ),
                const Text(
                  'KUALITAS / RESOLUSI',
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 11,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const SizedBox(
                  height: 6,
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final preset
                        in [
                      ResolutionPreset
                          .medium,
                      ResolutionPreset
                          .high,
                      ResolutionPreset
                          .veryHigh,
                      ResolutionPreset
                          .max,
                    ])
                      _choiceButton(
                        text:
                            _resolutionLabel(
                          preset,
                        ),
                        selected:
                            _resolutionPreset ==
                                preset,
                        onTap: () =>
                            _changeResolution(
                          preset,
                        ),
                      ),
                  ],
                ),
                const SizedBox(
                  height: 8,
                ),
                const Text(
                  'Resolusi maksimum bergantung '
                  'pada kemampuan kamera HP.',
                  style:
                      TextStyle(
                    color:
                        Colors.white38,
                    fontSize: 10,
                  ),
                ),
                const Divider(
                  color:
                      Colors.white12,
                ),
                const Text(
                  'ZOOM',
                  style:
                      TextStyle(
                    color:
                        Colors.white54,
                    fontSize: 11,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        min:
                            _minZoom,
                        max: _maxZoom <=
                                _minZoom
                            ? _minZoom +
                                1
                            : _maxZoom,
                        value:
                            _zoom.clamp(
                          _minZoom,
                          _maxZoom <=
                                  _minZoom
                              ? _minZoom +
                                  1
                              : _maxZoom,
                        ),
                        onChanged:
                            _setZoom,
                      ),
                    ),
                    Text(
                      '${_zoom.toStringAsFixed(1)}x',
                      style:
                          const TextStyle(
                        fontWeight:
                            FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                _settingRow(
                  icon:
                      Icons.folder_outlined,
                  title:
                      'Folder Foto',
                  value:
                      'Dokumentasi Barang Pecah',
                  onTap: () {
                    _showMessage(
                      _storagePath,
                    );
                  },
                ),
                _settingRow(
                  icon:
                      Icons.assessment_outlined,
                  title:
                      'Progress',
                  value:
                      '$_documentedCount / '
                      '$_totalItems',
                  onTap: () {
                    setState(() {
                      _settingsOpen =
                          false;
                      _statusPanelOpen =
                          true;
                    });
                  },
                ),
                _settingRow(
                  icon:
                      Icons.download_outlined,
                  title:
                      'Export Laporan',
                  value:
                      'CSV',
                  onTap:
                      _exportCsv,
                ),
                _settingRow(
                  icon:
                      Icons.delete_outline,
                  title:
                      'Reset Excel',
                  value:
                      '${_barang.length} data',
                  onTap:
                      _resetDatabase,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _choiceButton({
    required String text,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets
                .symmetric(
          horizontal: 12,
          vertical: 9,
        ),
        decoration:
            BoxDecoration(
          color: selected
              ? Colors.green
                  .withValues(
                  alpha: 0.85,
                )
              : Colors.white10,
          borderRadius:
              BorderRadius.circular(
            12,
          ),
          border: Border.all(
            color: selected
                ? Colors.greenAccent
                : Colors.white12,
          ),
        ),
        child: Text(
          text,
          style:
              const TextStyle(
            fontSize: 11,
            fontWeight:
                FontWeight.bold,
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
      borderRadius:
          BorderRadius.circular(
        12,
      ),
      child: Padding(
        padding:
            const EdgeInsets
                .symmetric(
          vertical: 8,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 21,
              color:
                  Colors.white70,
            ),
            const SizedBox(
              width: 12,
            ),
            Expanded(
              child: Text(
                title,
                style:
                    const TextStyle(
                  fontWeight:
                      FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: Text(
                value,
                textAlign:
                    TextAlign.right,
                overflow:
                    TextOverflow.ellipsis,
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExcelPanel() {
    return Positioned(
      left: 10,
      right: 10,
      bottom: 160,
      child: SafeArea(
        child: Container(
          padding:
              const EdgeInsets.all(
            14,
          ),
          decoration:
              BoxDecoration(
            color: const Color(
              0xFF171717,
            ).withValues(
              alpha: 0.97,
            ),
            borderRadius:
                BorderRadius.circular(
              20,
            ),
            border: Border.all(
              color:
                  Colors.white24,
            ),
          ),
          child: Column(
            mainAxisSize:
                MainAxisSize.min,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.table_view,
                    color:
                        Colors.greenAccent,
                  ),
                  SizedBox(
                    width: 10,
                  ),
                  Text(
                    'DATA EXCEL',
                    style:
                        TextStyle(
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: 10,
              ),
              SizedBox(
                width:
                    double.infinity,
                child:
                    FilledButton.icon(
                  onPressed:
                      _importExcel,
                  icon:
                      const Icon(
                    Icons.upload_file,
                  ),
                  label:
                      const Text(
                    'IMPORT / GANTI EXCEL',
                  ),
                ),
              ),
              const SizedBox(
                height: 5,
              ),
              Text(
                '${_barang.length} data barang',
                style:
                    const TextStyle(
                  color:
                      Colors.white54,
                  fontSize: 12,
                ),
              ),
              const SizedBox(
                height: 5,
              ),
              Row(
                children: [
                  Expanded(
                    child:
                        OutlinedButton.icon(
                      onPressed:
                          _exportCsv,
                      icon:
                          const Icon(
                        Icons
                            .download_outlined,
                      ),
                      label:
                          const Text(
                        'EXPORT',
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: 8,
                  ),
                  Expanded(
                    child:
                        TextButton(
                      onPressed:
                          _resetDatabase,
                      child:
                          const Text(
                        'RESET EXCEL',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusPanel() {
    return Positioned.fill(
      child: Container(
        color: Colors.black
            .withValues(
          alpha: 0.72,
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets
                        .fromLTRB(
                  12,
                  8,
                  12,
                  8,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'STATUS DOKUMENTASI',
                        style:
                            TextStyle(
                          fontSize: 18,
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _statusPanelOpen =
                              false;
                        });
                      },
                      icon:
                          const Icon(
                        Icons.close,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets
                        .symmetric(
                  horizontal: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child:
                          _statusCard(
                        title:
                            'TOTAL',
                        value:
                            '$_totalItems',
                        icon:
                            Icons.inventory_2_outlined,
                      ),
                    ),
                    const SizedBox(
                      width: 7,
                    ),
                    Expanded(
                      child:
                          _statusCard(
                        title:
                            'SUDAH',
                        value:
                            '$_documentedCount',
                        icon:
                            Icons.check_circle_outline,
                      ),
                    ),
                    const SizedBox(
                      width: 7,
                    ),
                    Expanded(
                      child:
                          _statusCard(
                        title:
                            'BELUM',
                        value:
                            '$_remainingCount',
                        icon:
                            Icons
                                .pending_outlined,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(
                height: 10,
              ),
              Expanded(
                child:
                    _barang.isEmpty
                        ? const Center(
                            child: Text(
                              'Import Excel terlebih dahulu.',
                              style:
                                  TextStyle(
                                color:
                                    Colors.white54,
                              ),
                            ),
                          )
                        : ListView.builder(
                            padding:
                                const EdgeInsets
                                    .fromLTRB(
                              12,
                              0,
                              12,
                              20,
                            ),
                            itemCount:
                                _barang.length,
                            itemBuilder:
                                (context,
                                    index) {
                              final entry =
                                  _barang
                                      .entries
                                      .elementAt(
                                index,
                              );

                              final documented =
                                  _isDocumented(
                                entry.key,
                              );

                              return Card(
                                color:
                                    const Color(
                                  0xFF1B1B1B,
                                ),
                                margin:
                                    const EdgeInsets
                                        .only(
                                  bottom:
                                      6,
                                ),
                                child:
                                    ListTile(
                                  onTap:
                                      () =>
                                          _selectNumber(
                                    entry.key,
                                  ),
                                  leading:
                                      CircleAvatar(
                                    backgroundColor:
                                        documented
                                            ? Colors.green
                                                .withValues(
                                                alpha:
                                                    0.20,
                                              )
                                            : Colors.orange
                                                .withValues(
                                                alpha:
                                                    0.20,
                                              ),
                                    child:
                                        Icon(
                                      documented
                                          ? Icons
                                              .check
                                          : Icons
                                              .schedule,
                                      color:
                                          documented
                                              ? Colors
                                                  .greenAccent
                                              : Colors
                                                  .orangeAccent,
                                    ),
                                  ),
                                  title:
                                      Text(
                                    '${entry.key} — '
                                    '${entry.value}',
                                    maxLines:
                                        2,
                                    overflow:
                                        TextOverflow
                                            .ellipsis,
                                    style:
                                        const TextStyle(
                                      fontWeight:
                                          FontWeight.bold,
                                    ),
                                  ),
                                  trailing:
                                      Text(
                                    documented
                                        ? 'SUDAH'
                                        : 'BELUM',
                                    style:
                                        TextStyle(
                                      color:
                                          documented
                                              ? Colors
                                                  .greenAccent
                                              : Colors
                                                  .orangeAccent,
                                      fontSize:
                                          10,
                                      fontWeight:
                                          FontWeight.bold,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding:
          const EdgeInsets.all(
        10,
      ),
      decoration:
          BoxDecoration(
        color:
            Colors.white10,
        borderRadius:
            BorderRadius.circular(
          14,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            size: 20,
          ),
          const SizedBox(
            height: 4,
          ),
          Text(
            value,
            style:
                const TextStyle(
              fontSize: 18,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
          Text(
            title,
            style:
                const TextStyle(
              color:
                  Colors.white54,
              fontSize: 9,
              fontWeight:
                  FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberPanel() {
    final found =
        _namaBarang.isNotEmpty;

    final documented =
        _nomorController
                .text
                .trim()
                .isNotEmpty &&
            _isDocumented(
              _nomorController.text
                  .trim(),
            );

    return Positioned.fill(
      child: Container(
        color: Colors.black
            .withValues(
          alpha: 0.72,
        ),
        child: Center(
          child: Container(
            width:
                MediaQuery.of(context)
                    .size
                    .width -
                40,
            padding:
                const EdgeInsets
                    .all(
              20,
            ),
            decoration:
                BoxDecoration(
              color:
                  const Color(
                0xFF1C1C1C,
              ),
              borderRadius:
                  BorderRadius.circular(
                24,
              ),
              border: Border.all(
                color:
                    Colors.white24,
              ),
            ),
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                const Icon(
                  Icons.tag,
                  size: 34,
                  color:
                      Colors.greenAccent,
                ),
                const SizedBox(
                  height: 8,
                ),
                const Text(
                  'NOMOR BARANG',
                  style:
                      TextStyle(
                    fontSize: 18,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),
                const SizedBox(
                  height: 15,
                ),
                TextField(
                  controller:
                      _nomorController,
                  focusNode:
                      _nomorFocus,
                  autofocus:
                      true,
                  keyboardType:
                      TextInputType
                          .number,
                  inputFormatters: [
                    FilteringTextInputFormatter
                        .digitsOnly,
                  ],
                  onChanged:
                      _searchNumber,
                  textAlign:
                      TextAlign.center,
                  style:
                      const TextStyle(
                    fontSize: 30,
                    fontWeight:
                        FontWeight.bold,
                  ),
                  decoration:
                      InputDecoration(
                    hintText:
                        '03',
                    filled:
                        true,
                    fillColor:
                        Colors.white10,
                    border:
                        OutlineInputBorder(
                      borderRadius:
                          BorderRadius
                              .circular(
                        16,
                      ),
                    ),
                  ),
                ),
                const SizedBox(
                  height: 12,
                ),
                if (found)
                  Text(
                    _namaBarang,
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
                else if (_nomorController
                    .text
                    .isNotEmpty)
                  const Text(
                    'Nomor tidak ditemukan di Excel',
                    textAlign:
                        TextAlign.center,
                    style:
                        TextStyle(
                      color:
                          Colors.redAccent,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  )
                else
                  const Text(
                    'Masukkan nomor dari Excel',
                    style:
                        TextStyle(
                      color:
                          Colors.white54,
                    ),
                  ),
                if (documented) ...[
                  const SizedBox(
                    height: 8,
                  ),
                  const Text(
                    '✓ SUDAH DIDOKUMENTASIKAN',
                    style:
                        TextStyle(
                      color:
                          Colors.orangeAccent,
                      fontWeight:
                          FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(
                  height: 18,
                ),
                Row(
                  children: [
                    Expanded(
                      child:
                          OutlinedButton(
                        onPressed:
                            _closeFloatingMenus,
                        child:
                            const Text(
                          'BATAL',
                        ),
                      ),
                    ),
                    const SizedBox(
                      width: 10,
                    ),
                    Expanded(
                      child:
                          FilledButton(
                        onPressed:
                            found
                                ? () {
                                    setState(() {
                                      _numberEditorOpen =
                                          false;
                                    });

                                    FocusScope.of(
                                      context,
                                    ).unfocus();
                                  }
                                : null,
                        child:
                            const Text(
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
          color: Colors.black
              .withValues(
            alpha: 0.32,
          ),
          child: Center(
            child: Column(
              mainAxisSize:
                  MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 54,
                  height: 54,
                  child:
                      CircularProgressIndicator(
                    strokeWidth: 4,
                  ),
                ),
                const SizedBox(
                  height: 14,
                ),
                const Text(
                  'MENYIMPAN FOTO...',
                  style:
                      TextStyle(
                    fontWeight:
                        FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                if (_timerSeconds >
                    0)
                  Padding(
                    padding:
                        const EdgeInsets
                            .only(
                      top: 8,
                    ),
                    child: Text(
                      'Timer aktif: '
                      '$_timerSeconds detik',
                      style:
                          const TextStyle(
                        color:
                            Colors.white54,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showMessage(
    String message,
  ) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content:
              Text(message),
          behavior:
              SnackBarBehavior.floating,
        ),
      );
  }
}

class _GridPainter
    extends CustomPainter {
  @override
  void paint(
    Canvas canvas,
    Size size,
  ) {
    final paint =
        Paint()
          ..color =
              Colors.white
                  .withValues(
            alpha: 0.35,
          )
          ..strokeWidth = 1;

    final thirdWidth =
        size.width / 3;

    final thirdHeight =
        size.height / 3;

    canvas.drawLine(
      Offset(
        thirdWidth,
        0,
      ),
      Offset(
        thirdWidth,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        thirdWidth * 2,
        0,
      ),
      Offset(
        thirdWidth * 2,
        size.height,
      ),
      paint,
    );

    canvas.drawLine(
      Offset(
        0,
        thirdHeight,
      ),
      Offset(
        size.width,
        thirdHeight,
      ),
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
