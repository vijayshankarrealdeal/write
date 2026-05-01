import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Renders an author / username as a tap target that routes to `/u/:authorId`.
/// Falls back to plain non-clickable text when [authorId] is empty (e.g.
/// offline records that never carried a server-side id).
class AuthorLink extends StatelessWidget {
  final String name;
  final String authorId;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final String prefix;

  const AuthorLink({
    super.key,
    required this.name,
    required this.authorId,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.prefix = '',
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(
      '$prefix$name',
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
    );

    if (authorId.isEmpty) return text;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => context.push('/u/$authorId'),
        child: text,
      ),
    );
  }
}
