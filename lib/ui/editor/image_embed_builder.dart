import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';

/// Renders image embeds inside the QuillEditor.
///
/// Handles three image source types:
///   1. `data:image/...;base64,...`  — instant local preview (no network)
///   2. `https://...`               — cached network image
///   3. Any other URL               — plain network image
class ImageEmbedBuilder extends EmbedBuilder {
  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final imageUrl = embedContext.node.value.data as String;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final placeholder = Container(
      height: 220,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Center(child: CupertinoActivityIndicator()),
    );

    final errorBox = Container(
      height: 180,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(CupertinoIcons.photo,
              color: isDark ? Colors.white24 : Colors.black26, size: 28),
          const SizedBox(height: 8),
          Text('Image could not be loaded',
              style: TextStyle(
                  color: isDark ? Colors.white30 : Colors.black26,
                  fontSize: 13)),
        ],
      ),
    );

    Widget imageWidget;

    if (imageUrl.startsWith('data:image')) {
      // ── Base64 data-URI  (instant local preview) ──
      try {
        final commaIdx = imageUrl.indexOf(',');
        final b64 = imageUrl.substring(commaIdx + 1);
        final bytes = base64Decode(b64);
        imageWidget = Image.memory(
          Uint8List.fromList(bytes),
          width: double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (_, e, s) => errorBox,
        );
      } catch (_) {
        imageWidget = errorBox;
      }
    } else if (imageUrl.startsWith('http')) {
      // ── Network URL (cached) ──
      imageWidget = CachedNetworkImage(
        imageUrl: imageUrl,
        width: double.infinity,
        fit: BoxFit.cover,
        placeholder: (_, u) => placeholder,
        errorWidget: (_, u, e) => errorBox,
      );
    } else {
      // ── Fallback ──
      imageWidget = CachedNetworkImage(
        imageUrl: imageUrl,
        width: double.infinity,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => errorBox,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: imageWidget,
      ),
    );
  }
}
