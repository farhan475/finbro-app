/// OCR text normalization, IDR amount extraction and fuzzy keyword matching.
/// Pure Dart so every rule is unit-testable with text fixtures.
library;

import 'date_time_parser.dart';

/// One OCR line after normalization. [corrected] is true when look-alike
/// characters inside numbers were repaired (e.g. `35.O00` → `35.000`), which
/// lowers confidence of values read from the line.
class NormalizedLine {
  const NormalizedLine(this.text, {this.corrected = false});
  final String text;
  final bool corrected;

  @override
  String toString() => corrected ? '$text (corrected)' : text;
}

/// Look-alike characters OCR often emits inside numbers.
const _digitLookAlikes = {
  'O': '0',
  'o': '0',
  'Q': '0',
  'I': '1',
  'l': '1',
  '|': '1',
  'S': '5',
  'B': '8',
  'Z': '2',
};

/// Look-alike digits OCR emits inside words (for keyword matching only).
const _letterLookAlikes = {'0': 'O', '1': 'I', '5': 'S', '8': 'B', '4': 'A'};

final _spaces = RegExp(r'[ \t\u00A0\u2007\u202F]+');
final _dashes = RegExp(r'[\u2010-\u2015\u2212]');
final _bullets = RegExp(r'[•·●◦▪|]\s');
final _currencyPrefix = RegExp(
  r'(?<![A-Za-z])(rp|idr)\s*[.:]?\s*(?=[-(]?[OoQIlSBZ.,]*\d)',
  caseSensitive: false,
);
final _splitThousands = RegExp(r'(\d)([.,]) (\d{3})(?!\d)');
final _groupedShape = RegExp(r'^-?\d{1,3}([.,]\d{3})+([.,]\d{1,2})?(,-|\.-)?$');
final _tokenCore = RegExp(r'^([(\[:=]*)(.*?)([)\]:;]*)$');
final _numericChars = RegExp(r'^[-\d.,:/]*$');

/// Splits raw OCR output into trimmed, non-empty normalized lines.
List<NormalizedLine> normalizeOcrLines(String raw) {
  final out = <NormalizedLine>[];
  for (final line in raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n')) {
    final n = normalizeOcrLine(line);
    if (n.text.isNotEmpty) out.add(n);
  }
  return out;
}

/// Normalizes a single line: unifies spaces/dashes, separates the `Rp`
/// prefix, re-joins `35. 000` and repairs look-alike characters in numbers.
NormalizedLine normalizeOcrLine(String line) {
  var s = line
      .replaceAll(_dashes, '-')
      .replaceAll(_bullets, ' ')
      .replaceAll(RegExp(r'[“”]'), '"')
      .replaceAll(RegExp(r'[‘’`´]'), "'")
      .replaceAll(_spaces, ' ')
      .trim();
  if (s.isEmpty) return const NormalizedLine('');
  s = s.replaceAllMapped(
    _currencyPrefix,
    (m) => '${m[1]!.toUpperCase() == 'IDR' ? 'IDR' : 'Rp'} ',
  );
  s = s.replaceAllMapped(_splitThousands, (m) => '${m[1]}${m[2]}${m[3]}');

  var corrected = false;
  final tokens = s.split(' ');
  for (var i = 0; i < tokens.length; i++) {
    final prev = i > 0 ? tokens[i - 1] : '';
    final fixed = _repairNumberToken(tokens[i], afterCurrency: prev == 'Rp' || prev == 'IDR');
    if (fixed != null) {
      tokens[i] = fixed;
      corrected = true;
    }
  }
  return NormalizedLine(tokens.join(' '), corrected: corrected);
}

/// Returns the repaired token, or null when it should stay untouched.
String? _repairNumberToken(String token, {required bool afterCurrency}) {
  final m = _tokenCore.firstMatch(token)!;
  final core = m[2]!;
  if (core.isEmpty) return null;
  var digits = 0;
  var lookAlikes = 0;
  final buf = StringBuffer();
  for (final ch in core.split('')) {
    if (_isDigit(ch)) {
      digits++;
      buf.write(ch);
    } else if (_digitLookAlikes.containsKey(ch)) {
      lookAlikes++;
      buf.write(_digitLookAlikes[ch]);
    } else if ('.,:/-'.contains(ch)) {
      buf.write(ch);
    } else {
      return null;
    }
  }
  if (lookAlikes == 0 || digits == 0) return null;
  final mapped = buf.toString();
  if (!_numericChars.hasMatch(mapped)) return null;
  final accept =
      _groupedShape.hasMatch(mapped) ||
      afterCurrency ||
      (digits >= lookAlikes && digits + lookAlikes >= 2);
  if (!accept) return null;
  return '${m[1]}$mapped${m[3]}';
}

bool _isDigit(String ch) {
  final c = ch.codeUnitAt(0);
  return c >= 0x30 && c <= 0x39;
}

/// Parses one IDR amount string: `Rp 35.000`, `35,000`, `35.000,00`,
/// `IDR 1.250.000`, `1,250,000.00`, `Rp35.000,-`, `35000`. Cents are rounded
/// half-up to whole rupiah. Returns null when the text is not an amount.
int? parseIdrAmount(String input) {
  var t = input.trim();
  t = t.replaceFirst(RegExp(r'^[-+(]\s*'), '');
  t = t.replaceFirst(RegExp(r'^(rp|idr)\s*[.:]?\s*', caseSensitive: false), '');
  t = t.replaceFirst(RegExp(r'^[-(]\s*'), '');
  t = t.replaceFirst(RegExp(r'(,-|\.-|-|\))$'), '');
  t = t.replaceAll(' ', '');
  if (t.isEmpty) return null;
  final repaired = _repairNumberToken(t, afterCurrency: true);
  if (repaired != null) t = repaired;
  if (!RegExp(r'^\d[\d.,]*$').hasMatch(t)) return null;
  final last = t.lastIndexOf(RegExp(r'[.,]'));
  if (last < 0) return int.tryParse(t);
  final head = t.substring(0, last);
  final tail = t.substring(last + 1);
  final headDigits = head.replaceAll(RegExp(r'[.,]'), '');
  if (headDigits.isEmpty) return null;
  if (tail.length == 3) {
    return int.tryParse(t.replaceAll(RegExp(r'[.,]'), ''));
  }
  if (tail.isNotEmpty && tail.length <= 2) {
    final whole = int.tryParse(headDigits);
    if (whole == null) return null;
    final cents = int.parse(tail.padRight(2, '0'));
    return whole + (cents >= 50 ? 1 : 0);
  }
  return null;
}

/// An amount found inside a line.
class AmountMatch {
  const AmountMatch({
    required this.value,
    required this.start,
    required this.end,
    required this.hasCurrency,
    required this.grouped,
    required this.negative,
  });

  final int value;
  final int start;
  final int end;

  /// Preceded by `Rp`/`IDR`.
  final bool hasCurrency;

  /// Written with thousand separators (`35.000`).
  final bool grouped;

  /// Written as `-35.000` or `(35.000)`.
  final bool negative;

  @override
  String toString() => 'AmountMatch($value${hasCurrency ? ', Rp' : ''})';
}

final _amountPattern = RegExp(
  r'(?<![A-WYZa-wyz0-9_.,/])(-\s?)?(?:(Rp|IDR)\s?)?(-\s?|\()?(\d{1,3}(?:[.,]\d{3})+(?:[.,]\d{1,2})?|\d+(?:[.,]\d{1,2})?)(?:,-|\.-)?\)?(?![\w%/]|[.,]\d|:\d)',
);

/// Amounts in [line] (already normalized). Dates, clock times, percentages,
/// quantities (`2x`) and long plain digit runs (account/reference numbers)
/// are ignored.
List<AmountMatch> findAmounts(String line) {
  final masked = maskDatesAndTimes(line);
  final out = <AmountMatch>[];
  for (final m in _amountPattern.allMatches(masked)) {
    final number = m[4]!;
    final hasCurrency = m[2] != null;
    final grouped = RegExp(r'^\d{1,3}([.,]\d{3})+').hasMatch(number);
    if (!hasCurrency && !grouped) {
      final plain = number.split(RegExp(r'[.,]')).first;
      if (plain.length > 9) continue;
      // A lone leading-zero run is an id/phone fragment, not money.
      if (plain.length > 1 && plain.startsWith('0')) continue;
    }
    final value = parseIdrAmount(number);
    if (value == null) continue;
    out.add(
      AmountMatch(
        value: value,
        start: m.start,
        end: m.end,
        hasCurrency: hasCurrency,
        grouped: grouped,
        negative: m[1] != null || (m[3] != null),
      ),
    );
  }
  return out;
}

/// Upper-case word tokens of [line] for keyword matching. Digits inside
/// mostly-letter tokens are mapped back to letters (`T0TAL` → `TOTAL`);
/// letter+number tokens such as `PB1` / `PPN10` are split (`PB`, `1`).
List<String> keywordWords(String line) {
  final out = <String>[];
  for (final raw in line.toUpperCase().split(RegExp(r'[^A-Z0-9]+'))) {
    if (raw.isEmpty) continue;
    final letters = raw.replaceAll(RegExp(r'[^A-Z]'), '').length;
    final digits = raw.length - letters;
    if (letters == 0 || digits == 0 || letters < digits) {
      out.add(raw);
      continue;
    }
    final edge = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(raw) ??
        RegExp(r'^(\d+)([A-Z]+)$').firstMatch(raw);
    final mappable = raw.split('').every((c) => !_isDigit(c) || _letterLookAlikes.containsKey(c));
    if (edge != null && !(digits == 1 && letters >= 4 && mappable)) {
      out
        ..add(edge[1]!)
        ..add(edge[2]!);
    } else if (mappable) {
      out.add(raw.split('').map((c) => _letterLookAlikes[c] ?? c).join());
    } else {
      out.add(raw);
    }
  }
  return out;
}

/// Position (word index) of [phrase] inside [words], or -1. With [fuzzy],
/// words of 5+ letters tolerate one OCR edit (`TOTAI`, `JUMLAN`).
int indexOfPhrase(List<String> words, String phrase, {bool fuzzy = true}) {
  final parts = phrase.split(' ');
  outer:
  for (var i = 0; i + parts.length <= words.length; i++) {
    for (var j = 0; j < parts.length; j++) {
      if (!_wordMatches(words[i + j], parts[j], fuzzy)) continue outer;
    }
    return i;
  }
  return -1;
}

bool hasPhrase(List<String> words, String phrase, {bool fuzzy = true}) =>
    indexOfPhrase(words, phrase, fuzzy: fuzzy) >= 0;

bool hasAnyPhrase(List<String> words, Iterable<String> phrases, {bool fuzzy = true}) =>
    phrases.any((p) => hasPhrase(words, p, fuzzy: fuzzy));

bool _wordMatches(String word, String keyword, bool fuzzy) {
  if (word == keyword) return true;
  if (!fuzzy || keyword.length < 5 || (word.length - keyword.length).abs() > 1) return false;
  return editDistanceAtMostOne(word, keyword);
}

/// Levenshtein distance between [a] and [b] is at most 1.
bool editDistanceAtMostOne(String a, String b) {
  if (a.length > b.length) return editDistanceAtMostOne(b, a);
  var i = 0;
  var j = 0;
  var edits = 0;
  while (i < a.length && j < b.length) {
    if (a[i] == b[j]) {
      i++;
      j++;
      continue;
    }
    if (++edits > 1) return false;
    if (a.length == b.length) i++;
    j++;
  }
  edits += (a.length - i) + (b.length - j);
  return edits <= 1;
}

/// Share of letters among non-space characters.
double letterRatio(String s) {
  final compact = s.replaceAll(' ', '');
  if (compact.isEmpty) return 0;
  final letters = RegExp(r'[A-Za-z]').allMatches(compact).length;
  return letters / compact.length;
}

int letterCount(String s) => RegExp(r'[A-Za-z]').allMatches(s).length;
