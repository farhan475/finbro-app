import '../../../core/database/app_database.dart';

/// Backup cannot be created, validated or restored; [message] is user-facing.
class BackupException implements Exception {
  const BackupException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// `manifest.json` inside a FinBro backup zip (09-security §5).
class BackupManifest {
  const BackupManifest({
    required this.schemaVersion,
    required this.createdAt,
    required this.transactions,
    required this.accounts,
    required this.attachments,
    required this.sha256,
    this.attachmentFiles = const {},
    this.app = appId,
    this.format = currentFormat,
  });

  static const appId = 'FinBro';
  static const currentFormat = 1;
  static const entryName = 'manifest.json';
  static const sqliteEntry = 'finbro.sqlite';
  static const attachmentsFolder = 'attachments';

  final String app;
  final int format;
  final int schemaVersion;
  final DateTime createdAt;
  final int transactions;
  final int accounts;

  /// Attachment rows in the database (files may be fewer if some were
  /// already missing when the backup was made).
  final int attachments;

  /// SHA-256 (hex) of the `finbro.sqlite` entry.
  final String sha256;

  /// attachments.id → zip entry (`attachments/<name>`), relative names only.
  final Map<String, String> attachmentFiles;

  Map<String, Object?> toJson() => {
    'app': app,
    'format': format,
    'schemaVersion': schemaVersion,
    'createdAt': isoLocal(createdAt),
    'counts': {
      'transactions': transactions,
      'accounts': accounts,
      'attachments': attachments,
    },
    'sha256': sha256,
    'attachmentFiles': attachmentFiles,
  };

  /// Throws [FormatException] when a required field is missing or mistyped.
  factory BackupManifest.fromJson(Map<String, dynamic> json) {
    T field<T>(Map<String, dynamic> m, String key) {
      final v = m[key];
      if (v is! T) throw FormatException('manifest field "$key" invalid');
      return v;
    }

    final counts = field<Map<String, dynamic>>(json, 'counts');
    final files = json['attachmentFiles'];
    if (files != null && files is! Map<String, dynamic>) {
      throw const FormatException('manifest field "attachmentFiles" invalid');
    }
    return BackupManifest(
      app: field<String>(json, 'app'),
      format: field<int>(json, 'format'),
      schemaVersion: field<int>(json, 'schemaVersion'),
      createdAt: DateTime.parse(field<String>(json, 'createdAt')),
      transactions: field<int>(counts, 'transactions'),
      accounts: field<int>(counts, 'accounts'),
      attachments: field<int>(counts, 'attachments'),
      sha256: field<String>(json, 'sha256'),
      attachmentFiles: {
        for (final e in ((files as Map<String, dynamic>?) ?? const {}).entries)
          e.key: e.value is String
              ? e.value as String
              : throw const FormatException('manifest attachment entry invalid'),
      },
    );
  }
}
