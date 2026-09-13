/// Minimal, dependency-free RFC 4180 CSV reader and writer.
///
/// Collection files exported from Moxfield, Archidekt, TCGplayer and plain
/// spreadsheets all claim to be CSV and all differ in the details: quoting, line
/// endings, byte order marks and doubled quotes inside quoted fields. This
/// handles the whole grammar so nothing above it has to think about it.
abstract final class Csv {
  static const int _quote = 0x22; // "
  static const int _comma = 0x2C; // ,
  static const int _cr = 0x0D;
  static const int _lf = 0x0A;
  static const int _bom = 0xFEFF;

  /// Parses [input] into rows of fields.
  ///
  /// Accepts CRLF, LF and bare CR line endings, strips a leading byte order
  /// mark, and honours RFC 4180 quoting, including doubled quotes and embedded
  /// newlines. A trailing newline does not produce a phantom empty row.
  static List<List<String>> parse(String input) {
    var text = input;
    if (text.isNotEmpty && text.codeUnitAt(0) == _bom) {
      text = text.substring(1);
    }

    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var i = 0;

    while (i < text.length) {
      final ch = text.codeUnitAt(i);

      if (inQuotes) {
        if (ch == _quote) {
          // A doubled quote inside a quoted field is one literal quote.
          if (i + 1 < text.length && text.codeUnitAt(i + 1) == _quote) {
            field.writeCharCode(_quote);
            i += 2;
            continue;
          }
          inQuotes = false;
          i++;
          continue;
        }
        field.writeCharCode(ch);
        i++;
        continue;
      }

      if (ch == _quote) {
        inQuotes = true;
        i++;
      } else if (ch == _comma) {
        row.add(field.toString());
        field.clear();
        i++;
      } else if (ch == _cr) {
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
        i += (i + 1 < text.length && text.codeUnitAt(i + 1) == _lf) ? 2 : 1;
      } else if (ch == _lf) {
        row.add(field.toString());
        field.clear();
        rows.add(row);
        row = <String>[];
        i++;
      } else {
        field.writeCharCode(ch);
        i++;
      }
    }

    // Flush the final line, but never invent an empty row after a trailing
    // line ending.
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    return rows;
  }

  /// Encodes [rows] as CSV text.
  static String encode(List<List<String>> rows, {String eol = '\r\n'}) =>
      rows.map((row) => row.map(escapeField).join(',')).join(eol);

  /// Quotes [value] only when the grammar actually requires it.
  static String escapeField(String value) {
    final needsQuotes =
        value.contains(',') ||
        value.contains('"') ||
        value.contains('\n') ||
        value.contains('\r');
    if (!needsQuotes) return value;
    return '"${value.replaceAll('"', '""')}"';
  }

  /// Maps a header row to trimmed, lowercase names and the column they occupy.
  ///
  /// The first occurrence of a repeated name wins, so a file with two "name"
  /// columns resolves deterministically instead of depending on column order.
  static Map<String, int> header(List<String> row) {
    final out = <String, int>{};
    for (var i = 0; i < row.length; i++) {
      final key = row[i].trim().toLowerCase();
      if (key.isEmpty) continue;
      out.putIfAbsent(key, () => i);
    }
    return out;
  }
}
