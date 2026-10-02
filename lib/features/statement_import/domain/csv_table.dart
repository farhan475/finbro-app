/// Raw CSV handling: text decoding, delimiter detection, RFC 4180 fields.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Decodes statement bytes: UTF-8 (with or without BOM), UTF-16 LE/BE with
/// BOM, otherwise Latin-1 (Windows exports with `Rp`/accented names).
String decodeStatementText(Uint8List bytes) {
  if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return _utf16(bytes, 2, littleEndian: true);
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) return _utf16(bytes, 2, littleEndian: false);
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

String _utf16(Uint8List b, int start, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = start; i + 1 < b.length; i += 2) {
    units.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
  }
  return String.fromCharCodes(units);
}

const _delimiters = [',', ';', '\t', '|'];

/// Picks the delimiter that splits the most lines into the same number
/// (≥ 2) of fields. Ties prefer the order `, ; tab |`.
String detectDelimiter(String text) {
  final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty).take(60).toList();
  var best = ',';
  var bestScore = -1;
  for (final d in _delimiters) {
    final counts = <int, int>{};
    for (final l in lines) {
      final n = splitCsvLine(l, d).length;
      if (n >= 2) counts[n] = (counts[n] ?? 0) + 1;
    }
    if (counts.isEmpty) continue;
    // Lines sharing the most common field count, weighted by that count.
    final top = counts.entries.reduce((a, b) => a.value > b.value || (a.value == b.value && a.key > b.key) ? a : b);
    final score = top.value * 100 + top.key;
    if (score > bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

/// Splits one physical line (quotes may not span lines here).
List<String> splitCsvLine(String line, String delimiter) => parseCsv(line, delimiter).firstOrNull ?? const [];

/// RFC 4180 parse: quoted fields may contain the delimiter, doubled quotes
/// and line breaks. Fields are trimmed; blank rows dropped.
List<List<String>> parseCsv(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = 0;
  void endField() {
    row.add(field.toString().trim());
    field.clear();
  }

  void endRow() {
    endField();
    if (row.any((f) => f.isNotEmpty)) rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final c = text[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(c);
      }
    } else if (c == '"' && field.toString().trim().isEmpty) {
      field.clear();
      quoted = true;
    } else if (c == delimiter) {
      endField();
    } else if (c == '\r' || c == '\n') {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      endRow();
    } else {
      field.write(c);
    }
    i++;
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}
