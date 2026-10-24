/// Result of a conservative text edit.
///
/// `found` is false when the expected declaration does not exist; the
/// content is then untouched. `changed` is false when the declaration
/// already had the requested value.
typedef Edit = ({String content, bool changed, bool found});

Edit unchanged(String content, {required bool found}) =>
    (content: content, changed: false, found: found);

Edit edited(String before, String after) =>
    (content: after, changed: after != before, found: true);

/// Replaces the first match of [pattern] with [by].
Edit replaceFirst(String content, RegExp pattern, String Function(Match) by) {
  final match = pattern.firstMatch(content);
  if (match == null) return unchanged(content, found: false);
  return edited(
    content,
    content.replaceRange(match.start, match.end, by(match)),
  );
}
