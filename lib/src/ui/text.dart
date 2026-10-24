final _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

/// Removes ANSI escape sequences.
String stripAnsi(String text) => text.replaceAll(_ansi, '');

/// Number of terminal columns used by [text] (ANSI codes excluded).
int visibleLength(String text) => stripAnsi(text).runes.length;

/// Pads [text] with spaces up to [width] visible columns.
String padRight(String text, int width) {
  final missing = width - visibleLength(text);
  return missing > 0 ? '$text${' ' * missing}' : text;
}

String padLeft(String text, int width) {
  final missing = width - visibleLength(text);
  return missing > 0 ? '${' ' * missing}$text' : text;
}

/// Cuts plain [text] to [width] columns, ending with [ellipsis].
String truncate(String text, int width, {String ellipsis = '…'}) {
  final runes = text.runes.toList();
  if (runes.length <= width) return text;
  final keep = (width - ellipsis.runes.length).clamp(0, runes.length);
  return '${String.fromCharCodes(runes.take(keep))}$ellipsis';
}

/// Word-wraps plain [text] to [width] columns. Long words are split.
List<String> wrap(String text, int width) {
  final result = <String>[];
  for (final paragraph in text.split('\n')) {
    final words = paragraph.split(' ').where((w) => w.isNotEmpty);
    var line = StringBuffer();
    var length = 0;
    for (var word in words) {
      while (word.runes.length > width) {
        if (length > 0) {
          result.add(line.toString());
          line = StringBuffer();
          length = 0;
        }
        final runes = word.runes.toList();
        result.add(String.fromCharCodes(runes.take(width)));
        word = String.fromCharCodes(runes.skip(width));
      }
      final wordLength = word.runes.length;
      if (length > 0 && length + 1 + wordLength > width) {
        result.add(line.toString());
        line = StringBuffer();
        length = 0;
      }
      if (length > 0) {
        line.write(' ');
        length++;
      }
      line.write(word);
      length += wordLength;
    }
    result.add(line.toString());
  }
  return result;
}

/// Formats [duration] as `0.4s`, `52.6s` or `1m 38s`.
String formatDuration(Duration duration) {
  final ms = duration.inMilliseconds;
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  if (minutes < 60) return '${minutes}m ${seconds}s';
  return '${duration.inHours}h ${minutes % 60}m';
}

/// Formats a byte count as `512 B`, `1.2 MB`, `3.4 GB`.
String formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0 ? '$bytes B' : '${value.toStringAsFixed(1)} ${units[unit]}';
}
