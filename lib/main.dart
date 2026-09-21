import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

late List<CameraDescription> cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = <CameraDescription>[];
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const DokumentasiApp());
}

class DokumentasiApp extends StatelessWidget {
  const DokumentasiApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CAMERA',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
      ),
      home: const CameraHomePage(),
    );
  }
}

enum CameraRatio { r4x3, r16x9, r1x1, full }

class CameraHomePage extends StatefulWidget {
  const CameraHomePage({super.key});
  @override
  State<CameraHomePage> createState() => _CameraHomePageState();
}

class _CameraHomePageState extends State<CameraHomePage>
    with WidgetsBindingObserver {
  CameraController? _camera;
  int _cameraIndex = 0;
  bool _initializing = true;
  bool _cameraBusy = false;
  bool _switchingCamera = false;
  bool _saving = false;
  int _cameraInitToken = 0;
  bool _flashOn = false;
  bool _gridOn = false;
  int _timerSeconds = 0;
  double _zoom = 1.0;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _exposure = 0.0;
  CameraRatio _ratio = CameraRatio.r4x3;
  ResolutionPreset _resolution = ResolutionPreset.high;
  final _numberController = TextEditingController();
  Map<String, String> _barang = {};
  String _namaBarang = '';
  String? _latestPhoto;
  List<File> _photos = [];
  Map<String, List<String>> _photoHistory = {};

  static const _folderPath = '/storage/emulated/0/Dokumentasi Barang Pecah';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    await _requestPermissions();
    await _loadPreferences();
    await _loadDatabase();
    await _loadPhotoHistory();
    try {
      cameras = await availableCameras();
    } catch (e) {
      cameras = <CameraDescription>[];
      if (mounted) _message('Kamera tidak tersedia: $e');
    }
    await _initializeCamera();
    if (mounted) setState(() => _initializing = false);
    await _refreshPhotos();
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();
  }

  Future<void> _loadPhotoHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('photo_history');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _photoHistory = decoded.map((k, v) => MapEntry(k.toString(), (v is List ? v.map((e) => e.toString()).toList() : <String>[])));
      }
    } catch (_) {
      _photoHistory = {};
    }
  }

  Future<void> _savePhotoHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('photo_history', jsonEncode(_photoHistory));
  }

  Future<void> _loadPreferences() async {
    final p = await SharedPreferences.getInstance();
    final ratio = p.getString('camera_ratio') ?? '4:3';
    final res = p.getString('camera_resolution') ?? 'high';
    _ratio = switch (ratio) {
      '16:9' => CameraRatio.r16x9,
      '1:1' => CameraRatio.r1x1,
      'FULL' => CameraRatio.full,
      _ => CameraRatio.r4x3,
    };
    _resolution = switch (res) {
      'low' => ResolutionPreset.low,
      'medium' => ResolutionPreset.medium,
      'veryHigh' => ResolutionPreset.veryHigh,
      'ultraHigh' => ResolutionPreset.ultraHigh,
      _ => ResolutionPreset.high,
    };
  }

  Future<void> _savePreferences() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('camera_ratio', _ratioText);
    await p.setString('camera_resolution', _resolution.name);
  }

  String get _ratioText => switch (_ratio) {
        CameraRatio.r16x9 => '16:9',
        CameraRatio.r1x1 => '1:1',
        CameraRatio.full => 'FULL',
        CameraRatio.r4x3 => '4:3',
      };

  double get _frameRatio => switch (_ratio) {
        CameraRatio.r16x9 => 16 / 9,
        CameraRatio.r1x1 => 1,
        CameraRatio.full => 9 / 16,
        CameraRatio.r4x3 => 4 / 3,
      };

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty || _cameraBusy) return;
    _cameraBusy = true;
    final token = ++_cameraInitToken;
    final selected = cameras[_cameraIndex.clamp(0, cameras.length - 1)];
    final controller = CameraController(
      selected,
      _resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      if (_flashOn) {
        try { await controller.setFlashMode(FlashMode.torch); } catch (_) {}
      }
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _zoom = _zoom.clamp(_minZoom, _maxZoom);
      await controller.setZoomLevel(_zoom);
      try { await controller.setExposureOffset(_exposure.clamp(-2.0, 2.0)); } catch (_) {}
      if (!mounted || token != _cameraInitToken) {
        await controller.dispose();
        return;
      }
      final previous = _camera;
      setState(() { _camera = controller; _switchingCamera = false; });
      await previous?.dispose();
    } catch (e) {
      await controller.dispose();
      if (mounted) {
        setState(() => _switchingCamera = false);
        _message('Kamera gagal dibuka: $e');
      }
    } finally {
      _cameraBusy = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      ++_cameraInitToken;
      final camera = _camera;
      _camera = null;
      camera?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed) {
      if (_camera == null) _initializeCamera();
    }
  }

  Future<void> _loadDatabase() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString('excel_database');
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _barang = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {
      _barang = {};
    }
  }

  String _normalizeNumber(String value) {
    final v = value.trim();
    if (v.isEmpty) return '';
    final noLeading = v.replaceFirst(RegExp(r'^0+'), '');
    return noLeading.isEmpty ? '0' : noLeading;
  }

  String? _findBarang(String input) {
    final wanted = _normalizeNumber(input);
    for (final entry in _barang.entries) {
      if (_normalizeNumber(entry.key) == wanted) return entry.value;
    }
    return null;
  }

  Future<void> _importExcel() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );
      if (result == null || result.files.single.path == null) return;
      final bytes = await File(result.files.single.path!).readAsBytes();
      final workbook = excel.Excel.decodeBytes(bytes);
      if (workbook.tables.isEmpty) {
        _message('Excel tidak memiliki sheet.');
        return;
      }
      final rows = workbook.tables.values.first.rows;
      final imported = <String, String>{};
      for (var i = 1; i < rows.length; i++) {
        if (rows[i].length < 2) continue;
        final no = rows[i][0]?.value?.toString().trim() ?? '';
        final name = rows[i][1]?.value?.toString().trim() ?? '';
        if (no.isNotEmpty && name.isNotEmpty) imported[no] = name;
      }
      if (imported.isEmpty) {
        _message('Tidak ditemukan data pada kolom A dan B.');
        return;
      }
      final p = await SharedPreferences.getInstance();
      await p.setString('excel_database', jsonEncode(imported));
      setState(() => _barang = imported);
      _message('Berhasil import ${imported.length} data barang.');
    } catch (e) {
      _message('Gagal membaca Excel: $e');
    }
  }

  Future<void> _resetDatabase() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hapus data Excel?'),
        content: const Text('Foto yang sudah tersimpan tidak ikut dihapus.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('HAPUS')),
        ],
      ),
    );
    if (yes != true) return;
    final p = await SharedPreferences.getInstance();
    await p.remove('excel_database');
    setState(() {
      _barang = {};
      _namaBarang = '';
      _numberControllerClear();
    });
    _message('Database Excel dihapus. Kamera tetap bisa digunakan.');
  }

  void _numberControllerClear() => _numberController.clear();

  String _cleanName(String text) {
    var s = text.replaceAll(RegExp(r'[\\/:*?"<>|]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s.replaceAll(RegExp(r'[. ]+$'), '');
    return s.isEmpty ? 'Barang' : s;
  }

  Future<Directory> _photoDirectory() async {
    Directory? base;
    if (Platform.isAndroid) {
      base = await getExternalStorageDirectory();
    }
    final dir = Directory('${(base ?? await getApplicationDocumentsDirectory()).path}/Dokumentasi Barang Pecah');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _uniqueFile(Directory dir, String baseName) async {
    var f = File('${dir.path}/$baseName.jpg');
    var n = 1;
    while (await f.exists()) {
      f = File('${dir.path}/${baseName}_$n.jpg');
      n++;
    }
    return f;
  }

  Future<void> _refreshPhotos() async {
    try {
      final dir = await _photoDirectory();
      if (!await dir.exists()) {
        if (mounted) setState(() => _photos = []);
        return;
      }
      final files = dir.listSync().whereType<File>().where((f) {
        final p = f.path.toLowerCase();
        return p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.png');
      }).toList();
      files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      if (mounted) {
        setState(() {
          _photos = files;
          _latestPhoto = files.isEmpty ? null : files.first.path;
        });
      }
    } catch (_) {}
  }

  Future<void> _takePhoto() async {
    if (_saving) return;
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      _message('Kamera belum siap.');
      return;
    }
    if (_timerSeconds > 0) {
      await _countdown();
      if (!mounted) return;
    }
    setState(() => _saving = true);
    try {
      final photo = await camera.takePicture();
      final raw = await File(photo.path).readAsBytes();
      var decoded = img.decodeImage(raw);
      if (decoded == null) throw Exception('Foto tidak dapat dibaca.');
      decoded = img.bakeOrientation(decoded);
      final targetRatio = _ratio == CameraRatio.full ? (MediaQuery.sizeOf(context).width / MediaQuery.sizeOf(context).height) : _frameRatio;
      final currentRatio = decoded.width / decoded.height;
      if ((currentRatio - targetRatio).abs() > .015) {
        int cropW = decoded.width;
        int cropH = decoded.height;
        if (currentRatio > targetRatio) {
          cropW = (decoded.height * targetRatio).round();
        } else {
          cropH = (decoded.width / targetRatio).round();
        }
        final x = ((decoded.width - cropW) / 2).round();
        final y = ((decoded.height - cropH) / 2).round();
        decoded = img.copyCrop(decoded, x: x, y: y, width: cropW, height: cropH);
      }
      final dir = await _photoDirectory();
      final entered = _numberController.text.trim();
      final matched = _findBarang(entered);
      String baseName;
      String? historyKey;
      if (matched != null) {
        baseName = '${_cleanName(entered)}_${_cleanName(matched)}';
        historyKey = _normalizeNumber(entered);
      } else if (entered.isNotEmpty) {
        baseName = '${_cleanName(entered)}_FOTO';
        historyKey = _normalizeNumber(entered);
      } else {
        baseName = 'FOTO_${DateTime.now().millisecondsSinceEpoch}';
      }
      final target = await _uniqueFile(dir, baseName);
      await target.writeAsBytes(img.encodeJpg(decoded, quality: 95), flush: true);
      if (historyKey != null) {
        _photoHistory.putIfAbsent(historyKey, () => <String>[]).add(target.path);
        await _savePhotoHistory();
      }
      await _refreshPhotos();
      if (mounted) {
        setState(() => _saving = false);
        _message('Foto tersimpan. Status barang: SUDAH DIFOTO.');
      }
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      _message('Gagal mengambil foto: $e');
    }
  }

  Future<void> _countdown() async {
    for (var i = _timerSeconds; i > 0; i--) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CountdownDialog(number: i),
      );
    }
  }

  Future<void> _toggleFlash() async {
    final camera = _camera;
    if (camera == null) return;
    _flashOn = !_flashOn;
    try {
      await camera.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
      setState(() {});
    } catch (_) {
      _flashOn = false;
      _message('Flash tidak didukung kamera ini.');
    }
  }

  Future<void> _switchCamera() async {
    if (cameras.length < 2 || _cameraBusy) return;
    setState(() { _cameraIndex = (_cameraIndex + 1) % cameras.length; _switchingCamera = true; });
    final old = _camera;
    _camera = null;
    await old?.dispose();
    await _initializeCamera();
  }

  Future<void> _showSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Pengaturan Kamera', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 18),
                  const Text('Rasio foto', style: TextStyle(fontWeight: FontWeight.bold)),
                  Wrap(
                    spacing: 8,
                    children: CameraRatio.values.map((r) => ChoiceChip(
                      label: Text(switch (r) { CameraRatio.r4x3 => '4:3', CameraRatio.r16x9 => '16:9', CameraRatio.r1x1 => '1:1', CameraRatio.full => 'FULL'}),
                      selected: _ratio == r,
                      onSelected: (_) { setState(() => _ratio = r); setSheet(() {}); },
                    )).toList(),
                  ),
                  const SizedBox(height: 18),
                  const Text('Resolusi', style: TextStyle(fontWeight: FontWeight.bold)),
                  DropdownButtonFormField<ResolutionPreset>(
                    value: _resolution,
                    items: const [
                      DropdownMenuItem(value: ResolutionPreset.low, child: Text('Rendah')),
                      DropdownMenuItem(value: ResolutionPreset.medium, child: Text('Sedang')),
                      DropdownMenuItem(value: ResolutionPreset.high, child: Text('Tinggi')),
                      DropdownMenuItem(value: ResolutionPreset.veryHigh, child: Text('Sangat tinggi')),
                      DropdownMenuItem(value: ResolutionPreset.ultraHigh, child: Text('Ultra tinggi')),
                    ],
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => _resolution = v);
                      setSheet(() {});
                      await _savePreferences();
                      await _initializeCamera();
                    },
                  ),
                  const SizedBox(height: 18),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Garis grid'),
                    value: _gridOn,
                    onChanged: (v) { setState(() => _gridOn = v); setSheet(() {}); },
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Timer'),
                    trailing: DropdownButton<int>(
                      value: _timerSeconds,
                      items: const [0, 3, 5, 10].map((v) => DropdownMenuItem(value: v, child: Text('${v}s'))).toList(),
                      onChanged: (v) { setState(() => _timerSeconds = v ?? 0); setSheet(() {}); },
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('Folder penyimpanan'),
                    subtitle: const Text('Penyimpanan aman aplikasi: Dokumentasi Barang Pecah'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () async { await _savePreferences(); if (context.mounted) Navigator.pop(context); },
                    icon: const Icon(Icons.check),
                    label: const Text('SIMPAN PENGATURAN'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _savePreferences();
  }

  Future<void> _showGallery() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoGalleryPage(
      photos: _photos,
      onChanged: _refreshPhotos,
    )));
    await _refreshPhotos();
  }

  Future<void> _showStatus() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoStatusPage(barang: _barang, history: _photoHistory)));
  }

  Future<void> _openEditor(File file) async {
    final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PhotoEditorPage(file: file)));
    if (changed == true) await _refreshPhotos();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), behavior: SnackBarBehavior.floating));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _numberController.dispose();
    super.dispose();
  }

  Widget _topButton(IconData icon, String label, VoidCallback onTap, {bool active = false}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: active ? Colors.amber : Colors.white, size: 23),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cameraPreview() {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) {
      return Stack(
        alignment: Alignment.center,
        children: [
          const ColoredBox(color: Colors.black),
          if (_switchingCamera || _initializing) const CircularProgressIndicator(color: Colors.white),
          if (!_initializing && !_switchingCamera) const Text('KAMERA TIDAK SIAP', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
        ],
      );
    }
    final ratio = _ratio == CameraRatio.full ? (MediaQuery.sizeOf(context).width / MediaQuery.sizeOf(context).height) : _frameRatio;
    return Center(
      child: AspectRatio(
        aspectRatio: ratio,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: camera.value.previewSize?.height ?? 1,
              height: camera.value.previewSize?.width ?? 1,
              child: CameraPreview(camera),
            ),
          ),
        ),
      ),
    );
  }

  Widget _gridOverlay() {
    if (!_gridOn) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        painter: GridPainter(),
        size: Size.infinite,
      ),
    );
  }

  Widget _bottomBar() {
    return Container(
      color: Colors.black,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 16),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            _BottomAction(icon: Icons.table_view_outlined, label: 'EXCEL', onTap: _importExcel),
            _BottomAction(icon: Icons.photo_library_outlined, label: '${_photos.length}', onTap: _showGallery, imagePath: _latestPhoto),
            _BottomAction(icon: Icons.fact_check_outlined, label: 'STATUS', onTap: _showStatus),
            Expanded(
              flex: 2,
              child: GestureDetector(
                onTap: _saving ? null : _takePhoto,
                child: Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 5)),
                    child: Container(margin: const EdgeInsets.all(5), decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
                  ),
                ),
              ),
            ),
            _BottomAction(icon: Icons.flip_camera_android_outlined, label: 'BALIK', onTap: _switchCamera),
            _BottomAction(icon: Icons.tune, label: _ratioText, onTap: _showSettings),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: Colors.black,
              child: Row(children: [
                _topButton(_flashOn ? Icons.flash_on : Icons.flash_off, 'FLASH', _toggleFlash, active: _flashOn),
                _topButton(Icons.timer_outlined, _timerSeconds == 0 ? 'TIMER' : '${_timerSeconds}s', _showSettings),
                _topButton(_gridOn ? Icons.grid_on : Icons.grid_off, 'GRID', () => setState(() => _gridOn = !_gridOn), active: _gridOn),
                _topButton(Icons.settings_outlined, 'SETTING', _showSettings),
              ]),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Colors.black, child: _cameraPreview()),
                  _gridOverlay(),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 14,
                    child: Column(
                      children: [
                        if (_barang.isNotEmpty || _numberController.text.isNotEmpty)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(color: Colors.black.withValues(alpha: .55), borderRadius: BorderRadius.circular(14)),
                            child: Text(
                              _namaBarang.isNotEmpty ? '${_numberController.text} • $_namaBarang' : 'Nomor belum ditemukan',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: _namaBarang.isNotEmpty ? Colors.white : Colors.amber, fontWeight: FontWeight.bold),
                            ),
                          ),
                        if (_maxZoom > _minZoom)
                          Row(children: [
                            const Icon(Icons.zoom_out, color: Colors.white, size: 18),
                            Expanded(child: Slider(value: _zoom, min: _minZoom, max: _maxZoom, onChanged: (v) async { setState(() => _zoom = v); await _camera?.setZoomLevel(v); })),
                            const Icon(Icons.zoom_in, color: Colors.white, size: 18),
                          ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Container(
              color: Colors.black,
              padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _numberController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (v) => setState(() => _namaBarang = _findBarang(v) ?? ''),
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      hintText: _barang.isEmpty ? 'Nomor barang (opsional)' : 'Nomor barang',
                      hintStyle: const TextStyle(color: Colors.white54),
                      prefixIcon: const Icon(Icons.tag, color: Colors.white70),
                      filled: true,
                      fillColor: const Color(0xFF202124),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(onPressed: _resetDatabase, color: Colors.white70, icon: const Icon(Icons.delete_sweep_outlined)),
              ]),
            ),
            _bottomBar(),
          ],
        ),
      ),
    );
  }
}

class _BottomAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? imagePath;
  const _BottomAction({required this.icon, required this.label, required this.onTap, this.imagePath});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white54, width: 1.5), color: Colors.white10),
              clipBehavior: Clip.antiAlias,
              child: imagePath != null ? Image.file(File(imagePath!), fit: BoxFit.cover) : Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(height: 3),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.white.withValues(alpha: .35)..strokeWidth = 1;
    canvas.drawLine(Offset(size.width / 3, 0), Offset(size.width / 3, size.height), p);
    canvas.drawLine(Offset(size.width * 2 / 3, 0), Offset(size.width * 2 / 3, size.height), p);
    canvas.drawLine(Offset(0, size.height / 3), Offset(size.width, size.height / 3), p);
    canvas.drawLine(Offset(0, size.height * 2 / 3), Offset(size.width, size.height * 2 / 3), p);
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _CountdownDialog extends StatefulWidget {
  final int number;
  const _CountdownDialog({required this.number});
  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}
class _CountdownDialogState extends State<_CountdownDialog> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 850), () { if (mounted) Navigator.pop(context); });
  }
  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.black87,
    child: SizedBox(height: 170, child: Center(child: Text('${widget.number}', style: const TextStyle(color: Colors.white, fontSize: 80, fontWeight: FontWeight.bold)))),
  );
}

class PhotoStatusPage extends StatelessWidget {
  final Map<String, String> barang;
  final Map<String, List<String>> history;
  const PhotoStatusPage({super.key, required this.barang, required this.history});

  @override
  Widget build(BuildContext context) {
    final keys = barang.keys.toList();
    var done = 0;
    for (final k in keys) { if ((history[k.isEmpty ? k : k.replaceFirst(RegExp(r'^0+'), '').isEmpty ? '0' : k.replaceFirst(RegExp(r'^0+'), '')] ?? const []).isNotEmpty) done++; }
    final pending = keys.length - done;
    return Scaffold(
      appBar: AppBar(title: const Text('STATUS FOTO')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Row(children: [
          Expanded(child: _StatusCard(title: 'TOTAL', value: '${keys.length}', icon: Icons.inventory_2_outlined)),
          const SizedBox(width: 8),
          Expanded(child: _StatusCard(title: 'SUDAH', value: '$done', icon: Icons.check_circle_outline)),
          const SizedBox(width: 8),
          Expanded(child: _StatusCard(title: 'BELUM', value: '$pending', icon: Icons.pending_outlined)),
        ])),
        Expanded(child: keys.isEmpty ? const Center(child: Text('Import Excel terlebih dahulu.')) : ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          itemCount: keys.length,
          separatorBuilder: (_, __) => const SizedBox(height: 6),
          itemBuilder: (_, i) {
            final no = keys[i];
            final normalizedNo = no.replaceFirst(RegExp(r'^0+'), '').isEmpty ? '0' : no.replaceFirst(RegExp(r'^0+'), '');
            final count = (history[normalizedNo] ?? const []).length;
            final doneItem = count > 0;
            return Card(child: ListTile(
              leading: CircleAvatar(child: Icon(doneItem ? Icons.check : Icons.hourglass_empty)),
              title: Text(no, style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(barang[no] ?? 'Barang'),
              trailing: Text(doneItem ? 'SUDAH DIFOTO\n$count FOTO' : 'BELUM DIFOTO', textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: doneItem ? Colors.green : Colors.orange)),
            ));
          },
        )),
      ]),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title, value;
  final IconData icon;
  const _StatusCard({required this.title, required this.value, required this.icon});
  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [Icon(icon), const SizedBox(height: 4), Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)), Text(title, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700))])));
}

class PhotoGalleryPage extends StatefulWidget {
  final List<File> photos;
  final Future<void> Function() onChanged;
  const PhotoGalleryPage({super.key, required this.photos, required this.onChanged});
  @override
  State<PhotoGalleryPage> createState() => _PhotoGalleryPageState();
}
class _PhotoGalleryPageState extends State<PhotoGalleryPage> {
  late List<File> photos;
  @override
  void initState() { super.initState(); photos = [...widget.photos]; }
  Future<void> _delete(File file) async {
    final yes = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('Hapus foto?'),
      content: Text(file.path.split('/').last),
      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('BATAL')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('HAPUS'))],
    ));
    if (yes != true) return;
    await file.delete();
    setState(() => photos.remove(file));
    await widget.onChanged();
  }
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Galeri (${photos.length})'), actions: [IconButton(onPressed: () async { await widget.onChanged(); }, icon: const Icon(Icons.refresh))]),
    body: photos.isEmpty ? const Center(child: Text('Belum ada foto.')) : GridView.builder(
      padding: const EdgeInsets.all(6),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemCount: photos.length,
      itemBuilder: (_, i) => GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PhotoViewerPage(file: photos[i], onDelete: () => _delete(photos[i])))),
        onLongPress: () => _delete(photos[i]),
        child: Image.file(photos[i], fit: BoxFit.cover),
      ),
    ),
  );
}

class PhotoViewerPage extends StatelessWidget {
  final File file;
  final Future<void> Function() onDelete;
  const PhotoViewerPage({super.key, required this.file, required this.onDelete});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Foto')),
    body: Column(children: [
      Expanded(child: InteractiveViewer(child: Center(child: Image.file(file)))),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: FilledButton.icon(onPressed: () async { final changed = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => PhotoEditorPage(file: file))); if (changed == true && context.mounted) Navigator.pop(context); }, icon: const Icon(Icons.edit), label: const Text('EDIT'))),
        const SizedBox(width: 10),
        IconButton.filled(onPressed: () async { await onDelete(); if (context.mounted) Navigator.pop(context); }, icon: const Icon(Icons.delete_outline)),
      ]))),
    ]),
  );
}

enum EditTool { effect, adjust, erase, crop, transform, annotate }
enum EditorEffect { natural, vivid, warm, cool, mono, document }
enum EraseMode { auto, manual }
enum AnnotationMode { circle, rectangle, arrow, text, number }

class PhotoEditorPage extends StatefulWidget {
  final File file;
  const PhotoEditorPage({super.key, required this.file});
  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  img.Image? _image;
  Uint8List? _previewBytes;
  final List<Uint8List> _undo = [];
  final List<Uint8List> _redo = [];
  final List<_EditorMark> _marks = [];
  final List<List<Offset>> _strokes = [];
  List<Offset> _currentStroke = [];
  EditTool _tool = EditTool.effect;
  EditorEffect _effect = EditorEffect.natural;
  EraseMode _eraseMode = EraseMode.auto;
  AnnotationMode _annotationMode = AnnotationMode.circle;
  double _brush = 42;
  double _brightness = 0;
  double _contrast = 0;
  double _saturation = 0;
  double _temperature = 0;
  double _sharpness = 0;
  double _highlights = 0;
  double _shadows = 0;
  double _cropStartX = .12;
  double _cropStartY = .12;
  double _cropEndX = .88;
  double _cropEndY = .88;
  Offset? _cropAnchor;
  Offset? _autoErasePoint;
  int _numberMarker = 1;
  bool _busy = false;
  bool _showBefore = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await widget.file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Format foto tidak dapat dibaca');
      if (!mounted) return;
      setState(() {
        _image = decoded;
        _previewBytes = Uint8List.fromList(img.encodeJpg(decoded, quality: 94));
      });
    } catch (e) {
      if (mounted) _message('Gagal membuka foto: $e');
    }
  }

  Future<void> _pushHistory() async {
    final image = _image;
    if (image == null) return;
    _undo.add(Uint8List.fromList(img.encodeJpg(image, quality: 92)));
    if (_undo.length > 8) _undo.removeAt(0);
    _redo.clear();
  }

  Future<void> _refreshPreview() async {
    final image = _image;
    if (image == null || !mounted) return;
    setState(() {
      _previewBytes = Uint8List.fromList(img.encodeJpg(image, quality: 94));
    });
  }

  Future<void> _undoEdit() async {
    if (_undo.isEmpty) return;
    final image = _image;
    if (image == null) return;
    _redo.add(Uint8List.fromList(img.encodeJpg(image, quality: 92)));
    final bytes = _undo.removeLast();
    final restored = img.decodeImage(bytes);
    if (restored == null) return;
    setState(() {
      _image = restored;
      _strokes.clear();
      _marks.clear();
      _autoErasePoint = null;
    });
    await _refreshPreview();
  }

  Future<void> _redoEdit() async {
    if (_redo.isEmpty) return;
    final image = _image;
    if (image == null) return;
    _undo.add(Uint8List.fromList(img.encodeJpg(image, quality: 92)));
    final bytes = _redo.removeLast();
    final restored = img.decodeImage(bytes);
    if (restored == null) return;
    setState(() => _image = restored);
    await _refreshPreview();
  }

  Future<void> _resetAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset semua edit?'),
        content: const Text('Foto akan kembali ke kondisi asli.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('BATAL')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('RESET')),
        ],
      ),
    );
    if (yes != true) return;
    final bytes = await widget.file.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return;
    _undo.clear();
    _redo.clear();
    _marks.clear();
    _strokes.clear();
    setState(() {
      _image = original;
      _effect = EditorEffect.natural;
      _brightness = 0;
      _contrast = 0;
      _saturation = 0;
      _temperature = 0;
      _sharpness = 0;
      _highlights = 0;
      _shadows = 0;
    });
    await _refreshPreview();
  }

  Future<void> _applyEffect(EditorEffect effect) async {
    final source = _image;
    if (source == null || _busy) return;
    await _pushHistory();
    setState(() {
      _busy = true;
      _effect = effect;
    });
    try {
      final out = img.Image.from(source);
      for (final pixel in out) {
        var r = pixel.r.toDouble();
        var g = pixel.g.toDouble();
        var b = pixel.b.toDouble();
        final avg = (r + g + b) / 3;
        switch (effect) {
          case EditorEffect.natural:
            break;
          case EditorEffect.vivid:
            r = avg + (r - avg) * 1.28;
            g = avg + (g - avg) * 1.28;
            b = avg + (b - avg) * 1.28;
            r = (r - 128) * 1.08 + 128;
            g = (g - 128) * 1.08 + 128;
            b = (b - 128) * 1.08 + 128;
            break;
          case EditorEffect.warm:
            r += 16;
            g += 5;
            b -= 12;
            break;
          case EditorEffect.cool:
            r -= 12;
            g += 2;
            b += 16;
            break;
          case EditorEffect.mono:
            r = g = b = .299 * r + .587 * g + .114 * b;
            break;
          case EditorEffect.document:
            r = g = b = .299 * r + .587 * g + .114 * b;
            r = g = b = (r - 128) * 1.45 + 128;
            break;
        }
        pixel.r = r.clamp(0, 255).round();
        pixel.g = g.clamp(0, 255).round();
        pixel.b = b.clamp(0, 255).round();
      }
      setState(() => _image = out);
      await _refreshPreview();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyAdjustments() async {
    final source = _image;
    if (source == null || _busy) return;
    if (_brightness == 0 && _contrast == 0 && _saturation == 0 && _temperature == 0 && _sharpness == 0 && _highlights == 0 && _shadows == 0) return;
    await _pushHistory();
    setState(() => _busy = true);
    try {
      var out = img.Image.from(source);
      final br = _brightness * 1.6;
      final ct = 1 + (_contrast / 100);
      final sat = 1 + (_saturation / 100);
      final temp = _temperature * 0.55;
      for (final pixel in out) {
        var r = pixel.r.toDouble();
        var g = pixel.g.toDouble();
        var b = pixel.b.toDouble();
        final lum = .299 * r + .587 * g + .114 * b;
        final shadowWeight = (1 - lum / 255).clamp(0.0, 1.0);
        final highlightWeight = (lum / 255).clamp(0.0, 1.0);
        r += br + (_shadows * shadowWeight) + (_highlights * highlightWeight);
        g += br + (_shadows * shadowWeight) + (_highlights * highlightWeight);
        b += br + (_shadows * shadowWeight) + (_highlights * highlightWeight);
        r = (r - 128) * ct + 128;
        g = (g - 128) * ct + 128;
        b = (b - 128) * ct + 128;
        final avg = (r + g + b) / 3;
        r = avg + (r - avg) * sat;
        g = avg + (g - avg) * sat;
        b = avg + (b - avg) * sat;
        r += temp;
        b -= temp;
        pixel.r = r.clamp(0, 255).round();
        pixel.g = g.clamp(0, 255).round();
        pixel.b = b.clamp(0, 255).round();
      }
      if (_sharpness > 0) {
        out = img.convolution(out, filter: [
          0, -1, 0,
          -1, 5 + (_sharpness / 25), -1,
          0, -1, 0,
        ]);
      }
      setState(() => _image = out);
      await _refreshPreview();
      setState(() {
        _brightness = 0;
        _contrast = 0;
        _saturation = 0;
        _temperature = 0;
        _sharpness = 0;
        _highlights = 0;
        _shadows = 0;
      });
      _message('Penyesuaian diterapkan.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rotate(int turns) async {
    final source = _image;
    if (source == null) return;
    await _pushHistory();
    var out = source;
    for (var i = 0; i < turns.abs(); i++) {
      out = turns > 0 ? img.copyRotate(out, angle: 90) : img.copyRotate(out, angle: -90);
    }
    setState(() => _image = out);
    await _refreshPreview();
  }

  Future<void> _flip(bool horizontal) async {
    final source = _image;
    if (source == null) return;
    await _pushHistory();
    final out = img.flip(source, direction: horizontal ? img.FlipDirection.horizontal : img.FlipDirection.vertical);
    setState(() => _image = out);
    await _refreshPreview();
  }

  Rect _imageRect(Size canvas) {
    final image = _image;
    if (image == null || image.width == 0 || image.height == 0) return Offset.zero & canvas;
    final scale = math.min(canvas.width / image.width, canvas.height / image.height);
    final w = image.width * scale;
    final h = image.height * scale;
    return Rect.fromLTWH((canvas.width - w) / 2, (canvas.height - h) / 2, w, h);
  }

  Offset _toNormalized(Offset p, Size canvas) {
    final rect = _imageRect(canvas);
    return Offset(
      ((p.dx - rect.left) / rect.width).clamp(0.0, 1.0),
      ((p.dy - rect.top) / rect.height).clamp(0.0, 1.0),
    );
  }

  Offset _toImagePoint(Offset normalized, img.Image image) => Offset(
        normalized.dx * (image.width - 1),
        normalized.dy * (image.height - 1),
      );

  Future<void> _autoEraseAt(Offset normalized) async {
    final source = _image;
    if (source == null || _busy) return;
    await _pushHistory();
    setState(() {
      _busy = true;
      _autoErasePoint = normalized;
    });
    try {
      final maxSide = 720;
      final scale = math.min(1.0, maxSide / math.max(source.width, source.height));
      final small = scale < 1 ? img.copyResize(source, width: (source.width * scale).round(), height: (source.height * scale).round()) : img.Image.from(source);
      final sx = (normalized.dx * (small.width - 1)).round().clamp(0, small.width - 1);
      final sy = (normalized.dy * (small.height - 1)).round().clamp(0, small.height - 1);
      final seed = small.getPixel(sx, sy);
      final mask = List<bool>.filled(small.width * small.height, false);
      final queue = <int>[sy * small.width + sx];
      mask[sy * small.width + sx] = true;
      final threshold = 34.0;
      var head = 0;
      var minX = sx, maxX = sx, minY = sy, maxY = sy;
      while (head < queue.length && queue.length < small.width * small.height * .28) {
        final index = queue[head++];
        final x = index % small.width;
        final y = index ~/ small.width;
        minX = math.min(minX, x); maxX = math.max(maxX, x); minY = math.min(minY, y); maxY = math.max(maxY, y);
        for (final n in const [
          [-1, 0], [1, 0], [0, -1], [0, 1]
        ]) {
          final nx = x + n[0], ny = y + n[1];
          if (nx < 0 || ny < 0 || nx >= small.width || ny >= small.height) continue;
          final ni = ny * small.width + nx;
          if (mask[ni]) continue;
          final c = small.getPixel(nx, ny);
          final d = math.sqrt(math.pow(c.r - seed.r, 2) + math.pow(c.g - seed.g, 2) + math.pow(c.b - seed.b, 2));
          if (d <= threshold) {
            mask[ni] = true;
            queue.add(ni);
          }
        }
      }
      if (queue.length < 12) {
        _message('Objek otomatis tidak cukup jelas. Gunakan MANUAL ERASER.');
        return;
      }
      final out = img.Image.from(source);
      final fullMinX = math.max(0, (minX / small.width * source.width).floor() - 3);
      final fullMaxX = math.min(source.width - 1, ((maxX + 1) / small.width * source.width).ceil() + 3);
      final fullMinY = math.max(0, (minY / small.height * source.height).floor() - 3);
      final fullMaxY = math.min(source.height - 1, ((maxY + 1) / small.height * source.height).ceil() + 3);
      _inpaintMask(out, source, (x, y) {
        final mx = (x / source.width * small.width).floor().clamp(0, small.width - 1);
        final my = (y / source.height * small.height).floor().clamp(0, small.height - 1);
        return mask[my * small.width + mx];
      }, fullMinX, fullMaxX, fullMinY, fullMaxY);
      setState(() => _image = out);
      await _refreshPreview();
      _message('Objek otomatis dihapus.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _inpaintMask(img.Image out, img.Image source, bool Function(int, int) isMasked, int minX, int maxX, int minY, int maxY) {
    final work = img.Image.from(source);
    final maxPass = math.max(8, math.min(28, ((maxX - minX + maxY - minY) / 20).round()));
    for (var pass = 0; pass < maxPass; pass++) {
      var changed = 0;
      for (var y = minY; y <= maxY; y++) {
        for (var x = minX; x <= maxX; x++) {
          if (!isMasked(x, y)) continue;
          final neighbors = <img.Color>[];
          for (final d in const [[-1, 0], [1, 0], [0, -1], [0, 1]]) {
            final nx = x + d[0], ny = y + d[1];
            if (nx < 0 || ny < 0 || nx >= source.width || ny >= source.height) continue;
            if (!isMasked(nx, ny)) neighbors.add(work.getPixel(nx, ny));
          }
          if (neighbors.isEmpty) continue;
          var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
          for (final c in neighbors) { r += c.r; g += c.g; b += c.b; a += c.a; }
          work.setPixel(x, y, img.ColorRgba8((r / neighbors.length).round(), (g / neighbors.length).round(), (b / neighbors.length).round(), (a / neighbors.length).round()));
          changed++;
        }
      }
      if (changed == 0) break;
    }
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        if (isMasked(x, y)) out.setPixel(x, y, work.getPixel(x, y));
      }
    }
  }

  void _addManualStroke(Offset normalized) {
    _currentStroke = [normalized];
  }

  void _continueManualStroke(Offset normalized) {
    if (_currentStroke.isEmpty) return;
    setState(() => _currentStroke.add(normalized));
  }

  void _finishManualStroke() {
    if (_currentStroke.isEmpty) return;
    setState(() {
      _strokes.add([..._currentStroke]);
      _currentStroke = [];
    });
  }

  Future<void> _applyManualErase() async {
    final source = _image;
    if (source == null || _strokes.isEmpty || _busy) return;
    await _pushHistory();
    setState(() => _busy = true);
    try {
      final out = img.Image.from(source);
      for (final stroke in _strokes) {
        for (final point in stroke) {
          final p = _toImagePoint(point, source);
          final radius = (_brush * source.width / 420).round().clamp(6, 180).toInt();
          _softErase(out, source, p.dx.round(), p.dy.round(), radius);
        }
      }
      setState(() {
        _image = out;
        _strokes.clear();
      });
      await _refreshPreview();
      _message('Area manual berhasil dihapus.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _softErase(img.Image out, img.Image src, int cx, int cy, int radius) {
    final ring = math.max(3, radius ~/ 2);
    final samples = <img.Color>[];
    for (var dy = -radius; dy <= radius; dy += math.max(2, radius ~/ 4)) {
      for (var dx = -radius; dx <= radius; dx += math.max(2, radius ~/ 4)) {
        final d = math.sqrt(dx * dx + dy * dy);
        if (d >= ring && d <= radius + 2) {
          samples.add(src.getPixel((cx + dx).clamp(0, src.width - 1), (cy + dy).clamp(0, src.height - 1)));
        }
      }
    }
    if (samples.isEmpty) return;
    var r = 0.0, g = 0.0, b = 0.0, a = 0.0;
    for (final c in samples) { r += c.r; g += c.g; b += c.b; a += c.a; }
    final fill = img.ColorRgba8((r / samples.length).round(), (g / samples.length).round(), (b / samples.length).round(), (a / samples.length).round());
    for (var y = math.max(0, cy - radius); y <= math.min(out.height - 1, cy + radius); y++) {
      for (var x = math.max(0, cx - radius); x <= math.min(out.width - 1, cx + radius); x++) {
        final d = math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2));
        if (d <= radius) {
          final alpha = (1 - d / radius).clamp(0.0, 1.0);
          final old = out.getPixel(x, y);
          out.setPixel(x, y, img.ColorRgba8(
            (old.r * (1 - alpha) + fill.r * alpha).round(),
            (old.g * (1 - alpha) + fill.g * alpha).round(),
            (old.b * (1 - alpha) + fill.b * alpha).round(),
            old.a.toInt(),
          ));
        }
      }
    }
  }

  Future<void> _applyCrop() async {
    final source = _image;
    if (source == null) return;
    final left = math.min(_cropStartX, _cropEndX).clamp(0.0, 1.0);
    final right = math.max(_cropStartX, _cropEndX).clamp(0.0, 1.0);
    final top = math.min(_cropStartY, _cropEndY).clamp(0.0, 1.0);
    final bottom = math.max(_cropStartY, _cropEndY).clamp(0.0, 1.0);
    final x = (left * source.width).round();
    final y = (top * source.height).round();
    final w = math.max(1, ((right - left) * source.width).round());
    final h = math.max(1, ((bottom - top) * source.height).round());
    await _pushHistory();
    final out = img.copyCrop(source, x: x.clamp(0, source.width - 1), y: y.clamp(0, source.height - 1), width: math.min(w, source.width - x), height: math.min(h, source.height - y));
    setState(() => _image = out);
    await _refreshPreview();
    _cropStartX = .12; _cropStartY = .12; _cropEndX = .88; _cropEndY = .88;
  }

  Future<void> _addTextMark(Offset normalized) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Tambahkan teks'),
        content: TextField(controller: controller, autofocus: true, decoration: const InputDecoration(hintText: 'Contoh: RETAK / PECAH / PENYOK')),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('BATAL')), FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('TAMBAH'))],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty) return;
    setState(() => _marks.add(_EditorMark(mode: AnnotationMode.text, start: normalized, end: normalized, text: text)));
  }

  Future<void> _saveEdited() async {
    final image = _image;
    if (image == null || _busy) return;
    setState(() => _busy = true);
    try {
      final out = img.Image.from(image);
      for (final mark in _marks) {
        _drawMark(out, mark);
      }
      final bytes = img.encodeJpg(out, quality: 95);
      var target = File(widget.file.path.replaceFirst(RegExp(r'\.[^.]+$'), '_EDIT.jpg'));
      var n = 1;
      while (await target.exists()) {
        target = File(widget.file.path.replaceFirst(RegExp(r'\.[^.]+$'), '_EDIT_$n.jpg'));
        n++;
      }
      await target.writeAsBytes(bytes, flush: true);
      if (mounted) {
        _message('Foto hasil edit berhasil disimpan.');
        Navigator.pop(context, true);
      }
    } catch (e) {
      _message('Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _drawCircleOutline(img.Image image, int cx, int cy, int radius, img.Color color, int thickness) {
    final outer = radius;
    final inner = math.max(0, radius - math.max(1, thickness));
    final minX = math.max(0, cx - outer);
    final maxX = math.min(image.width - 1, cx + outer);
    final minY = math.max(0, cy - outer);
    final maxY = math.min(image.height - 1, cy + outer);
    for (var y = minY; y <= maxY; y++) {
      for (var x = minX; x <= maxX; x++) {
        final d = math.sqrt(math.pow(x - cx, 2) + math.pow(y - cy, 2));
        if (d <= outer && d >= inner) image.setPixel(x, y, color);
      }
    }
  }

  void _drawMark(img.Image image, _EditorMark mark) {
    final sx = (mark.start.dx * image.width).round();
    final sy = (mark.start.dy * image.height).round();
    final ex = (mark.end.dx * image.width).round();
    final ey = (mark.end.dy * image.height).round();
    final color = img.ColorRgb8(255, 50, 50);
    final thickness = math.max(4, image.width ~/ 420);
    switch (mark.mode) {
      case AnnotationMode.circle:
        final cx = ((sx + ex) / 2).round();
        final cy = ((sy + ey) / 2).round();
        final radius = (math.max((ex - sx).abs(), (ey - sy).abs()) / 2).round();
        _drawCircleOutline(image, cx, cy, math.max(8, radius), color, thickness);
        break;
      case AnnotationMode.rectangle:
        img.drawRect(image, x1: math.min(sx, ex), y1: math.min(sy, ey), x2: math.max(sx, ex), y2: math.max(sy, ey), color: color, thickness: thickness);
        break;
      case AnnotationMode.arrow:
        img.drawLine(image, x1: sx, y1: sy, x2: ex, y2: ey, color: color, thickness: thickness);
        final angle = math.atan2(ey - sy, ex - sx);
        final len = math.max(18, image.width ~/ 28).toDouble();
        final a1 = angle + math.pi * .83;
        final a2 = angle - math.pi * .83;
        img.drawLine(image, x1: ex, y1: ey, x2: (ex + len * math.cos(a1)).round(), y2: (ey + len * math.sin(a1)).round(), color: color, thickness: thickness);
        img.drawLine(image, x1: ex, y1: ey, x2: (ex + len * math.cos(a2)).round(), y2: (ey + len * math.sin(a2)).round(), color: color, thickness: thickness);
        break;
      case AnnotationMode.text:
        img.drawString(image, mark.text ?? '', font: img.arial24, x: sx, y: sy, color: color);
        break;
      case AnnotationMode.number:
        _drawCircleOutline(image, sx, sy, math.max(22, image.width ~/ 70), color, thickness);
        img.drawString(image, mark.text ?? '1', font: img.arial24, x: sx - 7, y: sy - 12, color: img.ColorRgb8(255, 255, 255));
        break;
    }
  }

  void _message(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(s)));
  }

  String _effectName(EditorEffect e) => switch (e) {
        EditorEffect.natural => 'Natural',
        EditorEffect.vivid => 'Vivid',
        EditorEffect.warm => 'Warm',
        EditorEffect.cool => 'Cool',
        EditorEffect.mono => 'B&W',
        EditorEffect.document => 'Document',
      };

  String _toolName(EditTool t) => switch (t) {
        EditTool.effect => 'Effect',
        EditTool.adjust => 'Adjust',
        EditTool.erase => 'Eraser',
        EditTool.crop => 'Crop',
        EditTool.transform => 'Rotate / Flip',
        EditTool.annotate => 'Marking',
      };

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('EDIT FOTO', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip: 'Undo', onPressed: _undo.isEmpty || _busy ? null : _undoEdit, icon: const Icon(Icons.undo)),
          IconButton(tooltip: 'Redo', onPressed: _redo.isEmpty || _busy ? null : _redoEdit, icon: const Icon(Icons.redo)),
          IconButton(tooltip: 'Reset', onPressed: _busy ? null : _resetAll, icon: const Icon(Icons.restart_alt)),
          IconButton(tooltip: 'Simpan', onPressed: _busy ? null : _saveEdited, icon: const Icon(Icons.save_outlined)),
        ],
      ),
      body: image == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      return GestureDetector(
                        onTapDown: _tool == EditTool.erase && _eraseMode == EraseMode.auto
                            ? (d) => _autoEraseAt(_toNormalized(d.localPosition, c.biggest))
                            : _tool == EditTool.annotate && _annotationMode == AnnotationMode.text
                                ? (d) => _addTextMark(_toNormalized(d.localPosition, c.biggest))
                                : _tool == EditTool.annotate && _annotationMode == AnnotationMode.number
                                    ? (d) => setState(() => _marks.add(_EditorMark(mode: AnnotationMode.number, start: _toNormalized(d.localPosition, c.biggest), end: _toNormalized(d.localPosition, c.biggest), text: '${_numberMarker++}')))
                                    : null,
                        onPanStart: _tool == EditTool.erase && _eraseMode == EraseMode.manual
                            ? (d) => _addManualStroke(_toNormalized(d.localPosition, c.biggest))
                            : _tool == EditTool.crop
                                ? (d) {
                                    final n = _toNormalized(d.localPosition, c.biggest);
                                    setState(() { _cropAnchor = n; _cropStartX = n.dx; _cropStartY = n.dy; _cropEndX = n.dx; _cropEndY = n.dy; });
                                  }
                                : _tool == EditTool.annotate && (_annotationMode == AnnotationMode.circle || _annotationMode == AnnotationMode.rectangle || _annotationMode == AnnotationMode.arrow)
                                    ? (d) {
                                        final n = _toNormalized(d.localPosition, c.biggest);
                                        setState(() => _marks.add(_EditorMark(mode: _annotationMode, start: n, end: n)));
                                      }
                                    : null,
                        onPanUpdate: _tool == EditTool.erase && _eraseMode == EraseMode.manual
                            ? (d) => _continueManualStroke(_toNormalized(d.localPosition, c.biggest))
                            : _tool == EditTool.crop && _cropAnchor != null
                                ? (d) {
                                    final n = _toNormalized(d.localPosition, c.biggest);
                                    setState(() { _cropEndX = n.dx; _cropEndY = n.dy; });
                                  }
                                : _tool == EditTool.annotate && _marks.isNotEmpty && (_annotationMode == AnnotationMode.circle || _annotationMode == AnnotationMode.rectangle || _annotationMode == AnnotationMode.arrow)
                                    ? (d) {
                                        final n = _toNormalized(d.localPosition, c.biggest);
                                        setState(() => _marks[_marks.length - 1] = _marks.last.copyWith(end: n));
                                      }
                                    : null,
                        onPanEnd: _tool == EditTool.erase && _eraseMode == EraseMode.manual
                            ? (_) => _finishManualStroke()
                            : _tool == EditTool.crop
                                ? (_) => setState(() => _cropAnchor = null)
                                : null,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Center(
                              child: _showBefore ? Image.file(widget.file, fit: BoxFit.contain) : (_previewBytes == null ? const SizedBox() : Image.memory(_previewBytes!, fit: BoxFit.contain, gaplessPlayback: true)),
                            ),
                            if (_tool == EditTool.erase && _eraseMode == EraseMode.manual)
                              CustomPaint(painter: _EditorStrokePainter(_strokes, _currentStroke, _brush), size: Size.infinite),
                            if (_tool == EditTool.erase && _eraseMode == EraseMode.auto && _autoErasePoint != null)
                              CustomPaint(painter: _AutoPointPainter(_autoErasePoint!), size: Size.infinite),
                            if (_tool == EditTool.crop)
                              CustomPaint(painter: _CropPainter(_cropStartX, _cropStartY, _cropEndX, _cropEndY), size: Size.infinite),
                            if (_tool == EditTool.annotate)
                              CustomPaint(painter: _MarksPainter(_marks), size: Size.infinite),
                            if (_busy)
                              const ColoredBox(color: Color(0x55000000), child: Center(child: CircularProgressIndicator(color: Colors.white))),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                _toolBar(),
              ],
            ),
    );
  }

  Widget _toolBar() {
    return SafeArea(
      top: false,
      child: Container(
        color: const Color(0xFF101114),
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 66,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: EditTool.values.map((tool) => _EditToolButton(icon: switch (tool) { EditTool.effect => Icons.auto_awesome, EditTool.adjust => Icons.tune, EditTool.erase => Icons.auto_fix_high, EditTool.crop => Icons.crop, EditTool.transform => Icons.rotate_90_degrees_ccw, EditTool.annotate => Icons.draw_outlined }, label: _toolName(tool), active: _tool == tool, onTap: () => setState(() => _tool = tool))).toList(),
              ),
            ),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            _toolPanel(),
          ],
        ),
      ),
    );
  }

  Widget _toolPanel() {
    switch (_tool) {
      case EditTool.effect:
        return SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: EditorEffect.values.map((e) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(label: Text(_effectName(e)), selected: _effect == e, onSelected: (_) => _applyEffect(e)),
            )).toList(),
          ),
        );
      case EditTool.adjust:
        return Column(children: [
          _sliderRow('Brightness', _brightness, -100, 100, (v) => setState(() => _brightness = v)),
          _sliderRow('Contrast', _contrast, -100, 100, (v) => setState(() => _contrast = v)),
          _sliderRow('Saturation', _saturation, -100, 100, (v) => setState(() => _saturation = v)),
          _sliderRow('Temperature', _temperature, -100, 100, (v) => setState(() => _temperature = v)),
          _sliderRow('Sharpness', _sharpness, 0, 100, (v) => setState(() => _sharpness = v)),
          _sliderRow('Highlights', _highlights, -100, 100, (v) => setState(() => _highlights = v)),
          _sliderRow('Shadows', _shadows, -100, 100, (v) => setState(() => _shadows = v)),
          FilledButton.icon(onPressed: _busy ? null : _applyAdjustments, icon: const Icon(Icons.check), label: const Text('TERAPKAN ADJUST')),
        ]);
      case EditTool.erase:
        return Column(children: [
          SegmentedButton<EraseMode>(segments: const [ButtonSegment(value: EraseMode.auto, label: Text('AUTO'), icon: Icon(Icons.auto_fix_high)), ButtonSegment(value: EraseMode.manual, label: Text('MANUAL'), icon: Icon(Icons.brush_outlined))], selected: {_eraseMode}, onSelectionChanged: (s) => setState(() => _eraseMode = s.first)),
          const SizedBox(height: 8),
          Text(_eraseMode == EraseMode.auto ? 'Tap objek yang ingin dihapus. Aplikasi akan memilih area otomatis.' : 'Gambar pada objek yang ingin dihapus.', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          if (_eraseMode == EraseMode.manual) Row(children: [const Icon(Icons.brush, color: Colors.white70), Expanded(child: Slider(value: _brush, min: 12, max: 100, onChanged: (v) => setState(() => _brush = v))), Text('${_brush.round()}', style: const TextStyle(color: Colors.white70))]),
          if (_eraseMode == EraseMode.manual) FilledButton.icon(onPressed: _busy ? null : _applyManualErase, icon: const Icon(Icons.auto_fix_high), label: const Text('HAPUS AREA')),
        ]);
      case EditTool.crop:
        return Column(children: [
          const Text('Tarik pada foto untuk memilih area crop.', style: TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          Row(children: [Expanded(child: FilledButton.icon(onPressed: _busy ? null : _applyCrop, icon: const Icon(Icons.crop), label: const Text('CROP'))), const SizedBox(width: 8), OutlinedButton(onPressed: () => setState(() { _cropStartX = .12; _cropStartY = .12; _cropEndX = .88; _cropEndY = .88; }), child: const Text('RESET AREA'))]),
        ]);
      case EditTool.transform:
        return Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: _busy ? null : () => _rotate(1), icon: const Icon(Icons.rotate_right), label: const Text('PUTAR 90°')),
          FilledButton.icon(onPressed: _busy ? null : () => _rotate(2), icon: const Icon(Icons.screen_rotation_alt), label: const Text('180°')),
          OutlinedButton.icon(onPressed: _busy ? null : () => _flip(true), icon: const Icon(Icons.flip), label: const Text('FLIP H')),
          OutlinedButton.icon(onPressed: _busy ? null : () => _flip(false), icon: const Icon(Icons.flip_camera_android), label: const Text('FLIP V')),
        ]);
      case EditTool.annotate:
        return Column(children: [
          SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, children: AnnotationMode.values.map((m) => Padding(padding: const EdgeInsets.only(right: 7), child: ChoiceChip(label: Text(switch (m) { AnnotationMode.circle => 'LINGKARAN', AnnotationMode.rectangle => 'KOTAK', AnnotationMode.arrow => 'PANAH', AnnotationMode.text => 'TEKS', AnnotationMode.number => 'NOMOR' }), selected: _annotationMode == m, onSelected: (_) => setState(() => _annotationMode = m)))).toList())),
          const SizedBox(height: 6),
          const Text('Tandai bagian barang yang rusak sebelum menyimpan.', style: TextStyle(color: Colors.white70, fontSize: 12)),
          Row(children: [Expanded(child: OutlinedButton.icon(onPressed: _marks.isEmpty ? null : () => setState(() => _marks.removeLast()), icon: const Icon(Icons.undo), label: const Text('HAPUS TANDA TERAKHIR'))), const SizedBox(width: 8), OutlinedButton.icon(onPressed: _marks.isEmpty ? null : () => setState(() => _marks.clear()), icon: const Icon(Icons.clear_all), label: const Text('BERSIHKAN'))]),
        ]);
    }
  }

  Widget _sliderRow(String label, double value, double min, double max, ValueChanged<double> onChanged) {
    return Row(children: [SizedBox(width: 88, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))), Expanded(child: Slider(value: value.clamp(min, max), min: min, max: max, onChanged: onChanged)), SizedBox(width: 42, child: Text(value.round().toString(), textAlign: TextAlign.right, style: const TextStyle(color: Colors.white70, fontSize: 11)))]);
  }
}

class _EditorMark {
  final AnnotationMode mode;
  final Offset start;
  final Offset end;
  final String? text;
  const _EditorMark({required this.mode, required this.start, required this.end, this.text});
  _EditorMark copyWith({Offset? end}) => _EditorMark(mode: mode, start: start, end: end ?? this.end, text: text);
}

class _EditToolButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _EditToolButton({required this.icon, required this.label, required this.active, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(width: 82, child: InkWell(onTap: onTap, child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Container(width: 38, height: 38, decoration: BoxDecoration(color: active ? Colors.blue : Colors.white10, borderRadius: BorderRadius.circular(11)), child: Icon(icon, color: Colors.white, size: 20)), const SizedBox(height: 4), Text(label, style: TextStyle(color: active ? Colors.white : Colors.white60, fontSize: 10, fontWeight: FontWeight.w700))])));
}

class _EditorStrokePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final List<Offset> current;
  final double brush;
  _EditorStrokePainter(this.strokes, this.current, this.brush);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.red.withValues(alpha: .42)..strokeWidth = brush..strokeCap = StrokeCap.round..style = PaintingStyle.stroke;
    for (final stroke in [...strokes, if (current.isNotEmpty) current]) {
      for (var i = 1; i < stroke.length; i++) {
        canvas.drawLine(Offset(stroke[i - 1].dx * size.width, stroke[i - 1].dy * size.height), Offset(stroke[i].dx * size.width, stroke[i].dy * size.height), p);
      }
    }
  }
  @override
  bool shouldRepaint(covariant _EditorStrokePainter oldDelegate) => true;
}

class _AutoPointPainter extends CustomPainter {
  final Offset point;
  _AutoPointPainter(this.point);
  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(point.dx * size.width, point.dy * size.height);
    final p = Paint()..color = Colors.blueAccent..style = PaintingStyle.stroke..strokeWidth = 3;
    canvas.drawCircle(center, 28, p);
    canvas.drawLine(center - const Offset(38, 0), center + const Offset(38, 0), p);
    canvas.drawLine(center - const Offset(0, 38), center + const Offset(0, 38), p);
  }
  @override
  bool shouldRepaint(covariant _AutoPointPainter oldDelegate) => oldDelegate.point != point;
}

class _CropPainter extends CustomPainter {
  final double sx, sy, ex, ey;
  _CropPainter(this.sx, this.sy, this.ex, this.ey);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(math.min(sx, ex) * size.width, math.min(sy, ey) * size.height, math.max(sx, ex) * size.width, math.max(sy, ey) * size.height);
    final shade = Paint()..color = Colors.black.withValues(alpha: .48);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), shade);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), shade);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), shade);
    canvas.drawRect(rect, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
  }
  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) => true;
}

class _MarksPainter extends CustomPainter {
  final List<_EditorMark> marks;
  _MarksPainter(this.marks);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.redAccent..style = PaintingStyle.stroke..strokeWidth = 3;
    for (final m in marks) {
      final s = Offset(m.start.dx * size.width, m.start.dy * size.height);
      final e = Offset(m.end.dx * size.width, m.end.dy * size.height);
      switch (m.mode) {
        case AnnotationMode.circle:
          canvas.drawOval(Rect.fromPoints(s, e), p);
          break;
        case AnnotationMode.rectangle:
          canvas.drawRect(Rect.fromPoints(s, e), p);
          break;
        case AnnotationMode.arrow:
          canvas.drawLine(s, e, p);
          final angle = math.atan2(e.dy - s.dy, e.dx - s.dx);
          const len = 16.0;
          canvas.drawLine(e, e + Offset(math.cos(angle + 2.6) * len, math.sin(angle + 2.6) * len), p);
          canvas.drawLine(e, e + Offset(math.cos(angle - 2.6) * len, math.sin(angle - 2.6) * len), p);
          break;
        case AnnotationMode.text:
          final tp = TextPainter(text: TextSpan(text: m.text ?? '', style: const TextStyle(color: Colors.redAccent, fontSize: 22, fontWeight: FontWeight.w900)), textDirection: TextDirection.ltr)..layout();
          tp.paint(canvas, s);
          break;
        case AnnotationMode.number:
          canvas.drawCircle(s, 20, p);
          final tp = TextPainter(text: TextSpan(text: m.text ?? '1', style: const TextStyle(color: Colors.redAccent, fontSize: 20, fontWeight: FontWeight.w900)), textDirection: TextDirection.ltr)..layout();
          tp.paint(canvas, s - Offset(tp.width / 2, tp.height / 2));
          break;
      }
    }
  }
  @override
  bool shouldRepaint(covariant _MarksPainter oldDelegate) => true;
}
