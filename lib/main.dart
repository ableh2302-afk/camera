import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:excel/excel.dart' as excel;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
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

enum CameraRatio { r4x3, r16x9, r1x1 }

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
  bool _saving = false;
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
    await _refreshPhotos();
    await _initializeCamera();
    if (mounted) setState(() => _initializing = false);
  }

  Future<void> _requestPermissions() async {
    await Permission.camera.request();
    if (Platform.isAndroid) {
      await Permission.storage.request();
      await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _loadPreferences() async {
    final p = await SharedPreferences.getInstance();
    final ratio = p.getString('camera_ratio') ?? '4:3';
    final res = p.getString('camera_resolution') ?? 'high';
    _ratio = switch (ratio) {
      '16:9' => CameraRatio.r16x9,
      '1:1' => CameraRatio.r1x1,
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
        CameraRatio.r4x3 => '4:3',
      };

  double get _frameRatio => switch (_ratio) {
        CameraRatio.r16x9 => 16 / 9,
        CameraRatio.r1x1 => 1,
        CameraRatio.r4x3 => 4 / 3,
      };

  Future<void> _initializeCamera() async {
    if (cameras.isEmpty) return;
    await _camera?.dispose();
    final selected = cameras[_cameraIndex.clamp(0, cameras.length - 1)];
    final controller = CameraController(
      selected,
      _resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      await controller.setFlashMode(_flashOn ? FlashMode.torch : FlashMode.off);
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = await controller.getMaxZoomLevel();
      _zoom = _zoom.clamp(_minZoom, _maxZoom);
      await controller.setZoomLevel(_zoom);
      await controller.setExposureOffset(_exposure.clamp(-2.0, 2.0));
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (_) {
      await controller.dispose();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final camera = _camera;
    if (camera == null || !camera.value.isInitialized) return;
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      camera.dispose();
      _camera = null;
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
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
    final dir = Directory(_folderPath);
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
      final dir = Directory(_folderPath);
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
      final dir = await _photoDirectory();
      final entered = _numberController.text.trim();
      final matched = _findBarang(entered);
      String baseName;
      if (matched != null) {
        baseName = '${_cleanName(entered)}_${_cleanName(matched)}';
      } else if (entered.isNotEmpty) {
        baseName = '${_cleanName(entered)}_FOTO';
      } else {
        baseName = 'FOTO_${DateTime.now().millisecondsSinceEpoch}';
      }
      final target = await _uniqueFile(dir, baseName);
      await File(photo.path).copy(target.path);
      await _refreshPhotos();
      if (mounted) {
        setState(() => _saving = false);
        _message('Foto tersimpan di Dokumentasi Barang Pecah.');
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
    if (cameras.length < 2) return;
    setState(() => _cameraIndex = (_cameraIndex + 1) % cameras.length);
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
                      label: Text(switch (r) { CameraRatio.r4x3 => '4:3', CameraRatio.r16x9 => '16:9', CameraRatio.r1x1 => '1:1'}),
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
                    subtitle: const Text(_folderPath),
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
      return const Center(child: Icon(Icons.no_photography_outlined, color: Colors.white54, size: 64));
    }
    final nativeRatio = camera.value.aspectRatio;
    return Center(
      child: AspectRatio(
        aspectRatio: nativeRatio,
        child: CameraPreview(camera),
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
    if (_initializing) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
    }
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

class PhotoEditorPage extends StatefulWidget {
  final File file;
  const PhotoEditorPage({super.key, required this.file});
  @override
  State<PhotoEditorPage> createState() => _PhotoEditorPageState();
}

class _PhotoEditorPageState extends State<PhotoEditorPage> {
  img.Image? _image;
  final List<List<Offset>> _strokes = [];
  List<Offset> _current = [];
  bool _eraser = false;
  double _brush = 32;
  bool _busy = false;

  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final bytes = await widget.file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (mounted) setState(() => _image = decoded);
  }

  Future<void> _saveEdited() async {
    if (_image == null || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = img.encodeJpg(_image!, quality: 94);
      final dir = widget.file.parent;
      final base = widget.file.path.replaceFirst(RegExp(r'\.jpg$', caseSensitive: false), '_EDIT.jpg');
      var target = File(base);
      var n = 1;
      while (await target.exists()) { target = File(widget.file.path.replaceFirst(RegExp(r'\.jpg$', caseSensitive: false), '_EDIT_$n.jpg')); n++; }
      await target.writeAsBytes(bytes, flush: true);
      if (mounted) { _message('Hasil edit disimpan sebagai file baru.'); Navigator.pop(context, true); }
    } catch (e) {
      _message('Gagal menyimpan: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _applyEraser() {
    final source = _image;
    if (source == null || _strokes.isEmpty) return;
    final out = img.Image.from(source);
    for (final stroke in _strokes) {
      for (final point in stroke) {
        final x = (point.dx * source.width).round();
        final y = (point.dy * source.height).round();
        final r = (_brush * source.width / 360).round().clamp(4, 120).toInt();
        _fillLocal(out, source, x, y, r);
      }
    }
    setState(() { _image = out; _strokes.clear(); _current = []; _eraser = false; });
    _message('Area yang ditandai sudah dihapus/diperhalus.');
  }

  void _fillLocal(img.Image out, img.Image src, int cx, int cy, int r) {
    final samples = <img.Color>[];
    final ring = math.max(3, r ~/ 2);
    for (var dy = -r; dy <= r; dy += math.max(1, r ~/ 3)) {
      for (var dx = -r; dx <= r; dx += math.max(1, r ~/ 3)) {
        final d = math.sqrt(dx * dx + dy * dy);
        if (d >= ring && d <= r + 2) {
          final sx = (cx + dx).clamp(0, src.width - 1);
          final sy = (cy + dy).clamp(0, src.height - 1);
          samples.add(src.getPixel(sx, sy));
        }
      }
    }
    if (samples.isEmpty) return;
    var rr = 0.0, gg = 0.0, bb = 0.0, aa = 0.0;
    for (final c in samples) { rr += c.r; gg += c.g; bb += c.b; aa += c.a; }
    final avg = img.ColorRgba8((rr / samples.length).round(), (gg / samples.length).round(), (bb / samples.length).round(), (aa / samples.length).round());
    for (var y = math.max(0, cy - r); y <= math.min(out.height - 1, cy + r); y++) {
      for (var x = math.max(0, cx - r); x <= math.min(out.width - 1, cx + r); x++) {
        if (math.pow(x - cx, 2) + math.pow(y - cy, 2) <= r * r) out.setPixel(x, y, avg);
      }
    }
  }

  void _message(String s) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s))); }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Scaffold(
      appBar: AppBar(title: const Text('Editor Foto'), actions: [IconButton(onPressed: _saveEdited, icon: const Icon(Icons.save_outlined))]),
      body: image == null ? const Center(child: CircularProgressIndicator()) : Column(children: [
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            return GestureDetector(
              onPanStart: _eraser ? (d) => setState(() => _current = [_normalize(d.localPosition, c.biggest)]) : null,
              onPanUpdate: _eraser ? (d) => setState(() => _current.add(_normalize(d.localPosition, c.biggest))) : null,
              onPanEnd: _eraser ? (_) { if (_current.isNotEmpty) _strokes.add([..._current]); _current = []; } : null,
              child: Stack(fit: StackFit.expand, children: [
                InteractiveViewer(minScale: .5, maxScale: 4, child: Center(child: Image.file(widget.file, fit: BoxFit.contain))),
                if (_eraser) CustomPaint(painter: MaskPainter([..._strokes, if (_current.isNotEmpty) _current], _brush), size: Size.infinite),
              ]),
            );
          }),
        ),
        SafeArea(top: false, child: Container(color: Theme.of(context).colorScheme.surface, padding: const EdgeInsets.all(10), child: Column(children: [
          Row(children: [
            FilterChip(label: const Text('OBJECT ERASER'), selected: _eraser, onSelected: (v) => setState(() => _eraser = v)),
            const SizedBox(width: 8),
            IconButton(onPressed: _strokes.isEmpty ? null : () => setState(() => _strokes.removeLast()), icon: const Icon(Icons.undo)),
            IconButton(onPressed: () => setState(() => _strokes.clear()), icon: const Icon(Icons.refresh)),
            const Spacer(),
            FilledButton(onPressed: _busy ? null : _applyEraser, child: const Text('TERAPKAN')),
          ]),
          if (_eraser) Row(children: [const Icon(Icons.brush_outlined), Expanded(child: Slider(value: _brush, min: 12, max: 90, onChanged: (v) => setState(() => _brush = v))), Text('${_brush.round()}')]),
        ]))),
      ]),
    );
  }

  Offset _normalize(Offset p, Size size) => Offset((p.dx / size.width).clamp(0.0, 1.0), (p.dy / size.height).clamp(0.0, 1.0));
}

class MaskPainter extends CustomPainter {
  final List<List<Offset>> strokes;
  final double brush;
  MaskPainter(this.strokes, this.brush);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = Colors.red.withValues(alpha: .38)..strokeWidth = brush..strokeCap = StrokeCap.round;
    for (final s in strokes) {
      for (var i = 1; i < s.length; i++) canvas.drawLine(Offset(s[i - 1].dx * size.width, s[i - 1].dy * size.height), Offset(s[i].dx * size.width, s[i].dy * size.height), p);
    }
  }
  @override
  bool shouldRepaint(covariant MaskPainter oldDelegate) => true;
}
