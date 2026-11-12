/// Pure helpers: PIN format, storage limit choices, address parsing, formatting.
library;

abstract final class PinRules {
  static const int minLength = 4;
  static const int maxLength = 6;

  /// A PIN is 4 to 6 digits.
  static bool isValid(String? pin) =>
      pin != null && pin.length >= minLength && pin.length <= maxLength && RegExp(r'^[0-9]+$').hasMatch(pin);

  /// Error text for a text field, or null when the PIN is fine.
  static String? validate(String? pin) => isValid(pin) ? null : 'Use $minLength to $maxLength digits.';
}

abstract final class StorageLimits {
  /// Choices in MB. 0 means unlimited.
  static const List<int> options = [100, 250, 500, 1000, 2000, 0];

  static String label(int mb) {
    if (mb <= 0) return 'Unlimited';
    if (mb >= 1000 && mb % 1000 == 0) return '${mb ~/ 1000} GB';
    return '$mb MB';
  }

  /// The listed option closest to [mb] (0 stays unlimited), so an odd stored value still selects a segment.
  static int nearest(int mb) {
    if (mb <= 0) return 0;
    final finite = options.where((o) => o > 0);
    return finite.reduce((a, b) => (a - mb).abs() <= (b - mb).abs() ? a : b);
  }
}

abstract final class Addresses {
  /// Parses `host`, `host:port` or `http://host:port/`. Returns null when it is not an IPv4 address or
  /// host name with an optional valid port.
  static ({String host, int port})? parse(String input, {int defaultPort = 8765}) {
    var s = input.trim();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp(r'^https?://'), '').replaceFirst(RegExp(r'/.*$'), '');
    var port = defaultPort;
    final colon = s.lastIndexOf(':');
    if (colon >= 0) {
      final p = int.tryParse(s.substring(colon + 1));
      if (p == null || p < 1 || p > 65535) return null;
      port = p;
      s = s.substring(0, colon);
    }
    if (!RegExp(r'^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$').hasMatch(s)) return null;
    final ipLike = RegExp(r'^\d+(\.\d+){3}$').hasMatch(s);
    if (ipLike && s.split('.').any((o) => int.parse(o) > 255)) return null;
    return (host: s, port: port);
  }
}

abstract final class Fmt {
  static String bytes(int b) {
    if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (b >= 1024) return '${(b / 1024).round()} KB';
    return '$b B';
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// `Today 14:05`, or `12 Nov 14:05`.
  static String when(DateTime t, {DateTime? now}) {
    final n = now ?? DateTime.now();
    final time = '${_two(t.hour)}:${_two(t.minute)}';
    if (t.year == n.year && t.month == n.month && t.day == n.day) return 'Today $time';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day} ${months[t.month - 1]} $time';
  }
}
