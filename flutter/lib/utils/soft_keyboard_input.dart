/// Converts mobile IME text updates into ordered remote edits.
/// Bridge calls run on native workers, so issuing calls in Dart order alone
/// does not guarantee that Backspace reaches the session before replacement.
class SoftKeyboardInput {
  SoftKeyboardInput({
    required this.sendBackspace,
    required this.sendText,
    required this.onError,
    this.trace,
  });

  final Future<void> Function() sendBackspace;
  final Future<void> Function(String) sendText;
  final void Function(Object, StackTrace) onError;
  final void Function(String stage, int edit, int deletes, String text)? trace;
  int _nextEdit = 0;
  String _previous = '';
  Future<void> _pending = Future<void>.value();
  bool _disposed = false;
  bool _failed = false;

  Future<void> get pending => _pending;

  void reset(String value) {
    _previous = value;
  }

  void update(String value, {int composingStart = -1, int composingEnd = -1}) {
    if (_disposed || _failed) return;
    // Detect removal of padding before normalization can turn a vowel-only
    // replacement into an empty string (which must not delete remote text).
    final externalReplacement = _previous.isNotEmpty &&
        value.isNotEmpty &&
        _previous[0] == '1' &&
        value[0] != '1';
    // Cheonjiin uses arae-a/double-arae-a as temporary vowel strokes:
    // ㄹ -> ㄹㆍ -> ㄹᆢ -> 려. Legacy editors cannot reliably insert those
    // glyphs. Diff the text we actually sent, so 려 replaces ONE ㄹ, not two
    // characters that may not exist remotely. Committed archaic text is kept.
    if (composingStart >= 0 &&
        composingEnd > composingStart &&
        composingEnd <= value.length) {
      value = value.substring(0, composingStart) +
          value
              .substring(composingStart, composingEnd)
              .replaceAll(RegExp('[\u318d\u119e\u11a2]'), '') +
          value.substring(composingEnd);
    }
    var previous = _previous;
    _previous = value;
    // External replacement may remove the hidden field's backspace padding.
    if (externalReplacement) {
      previous = '';
    }
    if (value == previous) return;
    final maxCommon =
        value.length < previous.length ? value.length : previous.length;
    var common = 0;
    while (common < maxCommon && value[common] == previous[common]) {
      common++;
    }
    final deleteCount = previous.length - common;
    final replacement = value.substring(common);
    final edit = ++_nextEdit;
    trace?.call('queued', edit, deleteCount, replacement);

    _pending = _pending.then((_) async {
      if (_disposed || _failed) return;
      for (var i = 0; i < deleteCount; i++) {
        if (_disposed) return;
        trace?.call('backspace', edit, 1, '');
        await sendBackspace();
        trace?.call('backspace_done', edit, 1, '');
      }
      if (!_disposed && replacement.isNotEmpty) {
        trace?.call('text', edit, 0, replacement);
        await sendText(replacement);
        trace?.call('text_done', edit, 0, '');
      }
    }).catchError((Object error, StackTrace stack) {
      // The remote text is now unknown. Do not send further destructive diffs
      // after a failed bridge call, or replay a potentially delivered edit.
      _failed = true;
      if (!_disposed) onError(error, stack);
    });
  }

  void dispose() {
    _disposed = true;
  }
}
