import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:inkspacex/models/writing_model.dart';

class WritingTypeStyle {
  final Color accent;
  final IconData icon;
  final String tagline;
  final String prompt;

  const WritingTypeStyle({
    required this.accent,
    required this.icon,
    required this.tagline,
    required this.prompt,
  });
}

WritingTypeStyle styleFor(WritingType type) {
  switch (type) {
    case WritingType.creative:
      return const WritingTypeStyle(
        accent: Color(0xFFF59E0B),
        icon: CupertinoIcons.sparkles,
        tagline: 'Stories, poems, scripts',
        prompt: 'Invent a world.',
      );
    case WritingType.digitalContent:
      return const WritingTypeStyle(
        accent: Color(0xFF3B82F6),
        icon: CupertinoIcons.bolt_fill,
        tagline: 'Posts, threads, newsletters',
        prompt: 'Speak to the feed.',
      );
    case WritingType.personal:
      return const WritingTypeStyle(
        accent: Color(0xFFEC4899),
        icon: CupertinoIcons.heart_fill,
        tagline: 'Rants, letters, logs',
        prompt: 'Process your world.',
      );
    case WritingType.journalistic:
      return const WritingTypeStyle(
        accent: Color(0xFF10B981),
        icon: CupertinoIcons.news_solid,
        tagline: 'Articles, interviews, editorials',
        prompt: 'Put it on the record.',
      );
    case WritingType.marketing:
      return const WritingTypeStyle(
        accent: Color(0xFF8B5CF6),
        icon: CupertinoIcons.speaker_2_fill,
        tagline: 'Copy, campaigns, slogans',
        prompt: 'Move them to act.',
      );
  }
}
