/// Compact count formatter — abbreviates large numbers Insta-style.
///
///   999       → "999"
///   1_000     → "1k"
///   1_632     → "1.6k"
///   10_500    → "11k"
///   1_200_000 → "1.2M"
///
/// Used everywhere a like/comment/follower count is rendered so the UI
/// stays compact on small cards.
String formatCount(int n) {
  if (n < 1000) return '$n';
  if (n < 1000000) {
    final v = n / 1000;
    // 1.0k → "1k", 1.6k → "1.6k", 11k → "11k"
    if (v >= 10) return '${v.toStringAsFixed(0)}k';
    final s = v.toStringAsFixed(1);
    return s.endsWith('.0') ? '${s.substring(0, s.length - 2)}k' : '${s}k';
  }
  final v = n / 1000000;
  if (v >= 10) return '${v.toStringAsFixed(0)}M';
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? '${s.substring(0, s.length - 2)}M' : '${s}M';
}
