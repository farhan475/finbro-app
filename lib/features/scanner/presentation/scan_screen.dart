import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/theme/app_theme.dart';
import '../../../core/providers.dart';
import '../../../core/utilities/app_logger.dart';
import '../../../shared/widgets/fin_widgets.dart';
import '../data/image_preprocessor.dart';
import '../data/mlkit_ocr_engine.dart';
import '../domain/ocr_engine.dart';
import '../domain/scan_models.dart';
import '../domain/scan_parser.dart';
import 'crop_view.dart';
import 'scan_review_view.dart';

/// Capture/import → crop/rotate → preprocessing → OCR → parse → review
/// (07-ocr §3).
/// Nothing is written to the database until the review is confirmed.
class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final _picker = ImagePicker();

  /// Temporary files created in this session (picker copies, rotated copies).
  final Set<String> _tempFiles = {};
  bool _busy = false;
  _ScanResult? _result;

  /// Picked image waiting for the crop step.
  ({String path, ScanSource source})? _pending;

  Future<void> _start(ScanSource source) async {
    final XFile? picked;
    try {
      picked = await _picker.pickImage(
        source: source == ScanSource.receipt ? ImageSource.camera : ImageSource.gallery,
        imageQuality: 92,
      );
    } catch (e, s) {
      AppLogger.error('Gagal membuka kamera/galeri', e, s);
      if (mounted) showSnack(context, 'Gagal membuka ${source == ScanSource.receipt ? 'kamera' : 'galeri'}.');
      return;
    }
    if (picked == null || !mounted) return;
    _tempFiles.add(picked.path);
    setState(() => _pending = (path: picked!.path, source: source));
  }

  Future<void> _read(String original, ScanSource source, CropChoice choice) async {
    setState(() {
      _pending = null;
      _busy = true;
    });
    final engine = ref.read(ocrEngineProvider);
    final now = ref.read(clockProvider)();
    String? ocrError;
    var parse = ScanParse(source: source, rawText: '');
    try {
      var path = await ImagePreprocessor.prepare(original, quarterTurns: choice.quarterTurns, crop: choice.crop);
      _tempFiles.add(path);
      var ocr = await engine.recognize(path);
      final extra = ImagePreprocessor.quarterTurnsFor(ocr.dominantAngle);
      if (extra != 0) {
        // Text still sideways/upside-down: rotate the cropped copy and retry.
        path = await ImagePreprocessor.prepare(path, quarterTurns: extra);
        _tempFiles.add(path);
        ocr = await engine.recognize(path);
      }
      if (ocr.isEmpty) {
        ocrError = 'Tidak ada teks yang terbaca. Isi data secara manual.';
      } else {
        parse = parseScanText(source, ocr.text, now: now);
      }
    } on OcrUnavailableException catch (e) {
      ocrError = '${e.message}. Isi data secara manual.';
    } catch (e, s) {
      AppLogger.error('Scan gagal diproses', e, s);
      ocrError = 'Gambar gagal diproses. Isi data secara manual.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _result = _ScanResult(imagePath: original, parse: parse, ocrError: ocrError);
    });
  }

  Future<void> _close() async {
    await ImagePreprocessor.discard(_tempFiles);
    if (mounted) context.pop();
  }

  @override
  void dispose() {
    ImagePreprocessor.discard(_tempFiles);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final pending = _pending;
    return PopScope(
      canPop: result == null && pending == null && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (result != null || pending != null) {
          setState(() {
            _result = null;
            _pending = null;
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            pending != null
                ? 'Potong gambar'
                : result == null
                ? 'Scan'
                : 'Review ${result.parse.source.label.toLowerCase()}',
          ),
          leading: IconButton(
            tooltip: 'Tutup',
            icon: const Icon(Icons.close),
            onPressed: _busy ? null : _close,
          ),
        ),
        body: _busy
            ? const _Processing()
            : pending != null
            ? CropView(
                key: ValueKey(pending.path),
                imagePath: pending.path,
                onDone: (choice) => _read(pending.path, pending.source, choice),
              )
            : result == null
            ? _SourcePicker(onPick: _start, ocrSupported: ref.watch(ocrEngineProvider).isSupported)
            : ScanReviewView(
                key: ValueKey(result.imagePath),
                imagePath: result.imagePath,
                parse: result.parse,
                ocrError: result.ocrError,
                onSaved: _close,
                onRetake: () => setState(() => _result = null),
              ),
      ),
    );
  }
}

class _ScanResult {
  const _ScanResult({required this.imagePath, required this.parse, this.ocrError});
  final String imagePath;
  final ScanParse parse;
  final String? ocrError;
}

class _Processing extends StatelessWidget {
  const _Processing();

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(strokeWidth: 2),
        const SizedBox(height: 16),
        Text('Membaca teks…', style: context.text.titleSmall),
        const SizedBox(height: 4),
        Text('Diproses di perangkat, tanpa internet.', style: context.text.bodySmall),
      ],
    ),
  );
}

class _SourcePicker extends StatelessWidget {
  const _SourcePicker({required this.onPick, required this.ocrSupported});
  final ValueChanged<ScanSource> onPick;
  final bool ocrSupported;

  @override
  Widget build(BuildContext context) {
    final fin = context.fin;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text('Catat dari gambar', style: context.text.headlineSmall),
        const SizedBox(height: 6),
        Text(
          'Hasil scan selalu menjadi draft. Periksa dan konfirmasi sebelum tersimpan.',
          style: context.text.bodyMedium!.copyWith(color: fin.muted),
        ),
        const SizedBox(height: 20),
        _SourceCard(
          icon: Icons.photo_camera_outlined,
          title: 'Scan struk',
          subtitle: 'Foto struk belanja dengan kamera',
          onTap: () => onPick(ScanSource.receipt),
        ),
        const SizedBox(height: 12),
        _SourceCard(
          icon: Icons.image_outlined,
          title: 'Import screenshot',
          subtitle: 'Bukti transfer atau pembayaran dari galeri',
          onTap: () => onPick(ScanSource.screenshot),
        ),
        if (!ocrSupported) ...[
          const SizedBox(height: 20),
          FinCard(
            color: fin.surface2,
            child: Row(
              children: [
                Icon(Icons.info_outline, color: fin.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '$ocrUnsupportedMessage. Di perangkat ini gambar tetap bisa dilampirkan dan data diisi manual.',
                    style: context.text.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FinCard(
    onTap: onTap,
    padding: const EdgeInsets.all(18),
    child: Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: context.fin.primary, borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: context.fin.onPrimary),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.text.titleMedium),
              const SizedBox(height: 2),
              Text(subtitle, style: context.text.bodySmall),
            ],
          ),
        ),
        Icon(Icons.chevron_right, color: context.fin.muted),
      ],
    ),
  );
}
