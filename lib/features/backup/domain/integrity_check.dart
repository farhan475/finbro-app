import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../core/database/app_database.dart';
import '../../../core/settings/app_settings_repository.dart';
import '../../../core/storage/attachment_storage.dart';
import '../../../core/utilities/app_logger.dart';

/// app_settings key holding the latest [IntegrityReport] as JSON.
const integrityReportKey = 'integrity_report';

/// Result of the 09-security §8 checks: SQLite integrity, foreign keys,
/// invalid amounts and orphan attachments.
class IntegrityReport {
  const IntegrityReport({
    required this.checkedAt,
    required this.trigger,
    this.databaseProblems = const [],
    this.missingFiles = const [],
    this.orphanFiles = const [],
    this.checksumMismatches = const [],
  });

  final DateTime checkedAt;

  /// `startup` (after abnormal termination), `restore` or `manual`.
  final String trigger;
  final List<String> databaseProblems;

  /// attachments.local_path values whose file no longer exists.
  final List<String> missingFiles;

  /// Files in the attachment directory not referenced by any row.
  final List<String> orphanFiles;

  /// Files whose SHA-256 no longer matches the stored `fileSha256`.
  final List<String> checksumMismatches;

  bool get ok =>
      databaseProblems.isEmpty &&
      missingFiles.isEmpty &&
      orphanFiles.isEmpty &&
      checksumMismatches.isEmpty;

  /// Human-readable lines for banners and the log screen.
  List<String> get summary => [
    ...databaseProblems,
    if (missingFiles.isNotEmpty) '${missingFiles.length} lampiran hilang (file tidak ditemukan)',
    if (orphanFiles.isNotEmpty) '${orphanFiles.length} file lampiran tanpa transaksi',
    if (checksumMismatches.isNotEmpty)
      '${checksumMismatches.length} lampiran berubah (checksum tidak cocok)',
  ];

  Map<String, Object?> toJson() => {
    'checkedAt': isoLocal(checkedAt),
    'trigger': trigger,
    'databaseProblems': databaseProblems,
    'missingFiles': missingFiles,
    'orphanFiles': orphanFiles,
    if (checksumMismatches.isNotEmpty) 'checksumMismatches': checksumMismatches,
  };

  static IntegrityReport? tryParse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      List<String> list(String k) => [for (final v in (m[k] as List? ?? const [])) v.toString()];
      return IntegrityReport(
        checkedAt: DateTime.parse(m['checkedAt'] as String),
        trigger: m['trigger'] as String? ?? 'manual',
        databaseProblems: list('databaseProblems'),
        missingFiles: list('missingFiles'),
        orphanFiles: list('orphanFiles'),
        checksumMismatches: list('checksumMismatches'),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Runs every integrity check against [db] and the attachment directory.
Future<IntegrityReport> runIntegrityCheck(
  AppDatabase db,
  Directory attachmentsDir, {
  required DateTime now,
  required String trigger,
}) async {
  final dbProblems = await db.integrityProblems();
  final rows = await db.select(db.attachments).get();
  final referenced = <String>{};
  final missing = <String>[];
  final mismatched = <String>[];
  for (final r in rows) {
    final path = p.normalize(r.localPath);
    referenced.add(path);
    final f = File(path);
    if (!await f.exists()) {
      missing.add(r.localPath);
      continue;
    }
    if (r.fileSha256 != null) {
      final actual = await AttachmentStorage.hashFile(f);
      if (actual != r.fileSha256!.toLowerCase()) mismatched.add(r.localPath);
    }
  }
  final orphans = <String>[];
  if (await attachmentsDir.exists()) {
    await for (final e in attachmentsDir.list()) {
      if (e is File && !referenced.contains(p.normalize(e.path))) orphans.add(e.path);
    }
  }
  final report = IntegrityReport(
    checkedAt: now,
    trigger: trigger,
    databaseProblems: dbProblems,
    missingFiles: missing,
    orphanFiles: orphans,
    checksumMismatches: mismatched,
  );
  if (report.ok) {
    AppLogger.info('Integrity check ($trigger): OK');
  } else {
    AppLogger.error('Integrity check ($trigger): ${report.summary.join('; ')}');
  }
  return report;
}

Future<void> saveIntegrityReport(AppSettingsRepository settings, IntegrityReport report) =>
    settings.set(integrityReportKey, jsonEncode(report.toJson()));

/// Deletes orphan files (no row references them) listed in [report]. Paths
/// outside the attachments directory are never touched.
Future<int> deleteOrphanFiles(IntegrityReport report) async {
  var deleted = 0;
  for (final path in report.orphanFiles) {
    try {
      if (!await AttachmentStorage.isManaged(path)) {
        AppLogger.info('File di luar penyimpanan aplikasi tidak dihapus: $path');
        continue;
      }
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        deleted++;
      }
    } catch (e, s) {
      AppLogger.error('Gagal menghapus file lampiran yatim $path', e, s);
    }
  }
  return deleted;
}

/// Latest stored integrity report (null when never run or dismissed).
final integrityReportProvider = Provider<IntegrityReport?>(
  (ref) => IntegrityReport.tryParse(ref.watch(appSettingsProvider).value?[integrityReportKey]),
);
