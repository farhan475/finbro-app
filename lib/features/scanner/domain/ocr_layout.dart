/// Rebuilds visual rows from OCR line boxes. ML Kit groups text in blocks,
/// so a receipt's label column ("TOTAL") and value column ("35.000") often
/// arrive as separate blocks; joining lines that share a baseline restores
/// "TOTAL  35.000" for the parsers.
library;

class OcrLine {
  const OcrLine(this.text, {required this.left, required this.top, required this.right, required this.bottom});

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get height => bottom - top;
  double get centerY => (top + bottom) / 2;
}

/// Joins [lines] into newline-separated rows, top to bottom, cells left to
/// right separated by two spaces.
String layoutRows(List<OcrLine> lines) {
  final items = [for (final l in lines) if (l.text.trim().isNotEmpty) l];
  if (items.isEmpty) return '';
  final heights = [for (final l in items) l.height]..sort();
  final median = heights[heights.length ~/ 2];
  final tolerance = (median <= 0 ? 1.0 : median) * 0.5;

  items.sort((a, b) => a.centerY.compareTo(b.centerY));
  final rows = <List<OcrLine>>[];
  final rowCenters = <double>[];
  for (final line in items) {
    var placed = false;
    for (var r = rows.length - 1; r >= 0 && r >= rows.length - 3; r--) {
      if ((line.centerY - rowCenters[r]).abs() > tolerance) continue;
      final overlapsHorizontally = rows[r].any((o) => line.left < o.right && line.right > o.left);
      if (overlapsHorizontally) continue;
      rows[r].add(line);
      rowCenters[r] = rows[r].map((l) => l.centerY).reduce((a, b) => a + b) / rows[r].length;
      placed = true;
      break;
    }
    if (!placed) {
      rows.add([line]);
      rowCenters.add(line.centerY);
    }
  }
  final order = List<int>.generate(rows.length, (i) => i)
    ..sort((a, b) => rowCenters[a].compareTo(rowCenters[b]));
  return order.map((i) {
    final row = rows[i]..sort((a, b) => a.left.compareTo(b.left));
    return row.map((l) => l.text.trim()).join('  ');
  }).join('\n');
}
