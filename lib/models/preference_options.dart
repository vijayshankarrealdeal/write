import 'package:flutter/cupertino.dart';

/// Shared option catalog for user preferences (onboarding + post-signup editor).
/// Values are persisted; labels and icons are presentation only.
class PreferenceOption {
  final String value;
  final String label;
  final String? description;
  final IconData? icon;

  const PreferenceOption({
    required this.value,
    required this.label,
    this.description,
    this.icon,
  });
}

const kRoleOptions = <PreferenceOption>[
  PreferenceOption(
    value: 'writer',
    label: 'Writer',
    description: 'I come here to create',
    icon: CupertinoIcons.pencil_outline,
  ),
  PreferenceOption(
    value: 'reader',
    label: 'Reader',
    description: 'I come here to discover',
    icon: CupertinoIcons.book,
  ),
  PreferenceOption(
    value: 'both',
    label: 'Both',
    description: 'I write and I read',
    icon: CupertinoIcons.sparkles,
  ),
];

const kExperienceOptions = <PreferenceOption>[
  PreferenceOption(
    value: 'beginner',
    label: 'Just starting',
    description: 'New to writing',
    icon: CupertinoIcons.leaf_arrow_circlepath,
  ),
  PreferenceOption(
    value: 'hobbyist',
    label: 'Hobbyist',
    description: 'I write for fun',
    icon: CupertinoIcons.heart,
  ),
  PreferenceOption(
    value: 'experienced',
    label: 'Experienced',
    description: 'Been at it for years',
    icon: CupertinoIcons.flame,
  ),
  PreferenceOption(
    value: 'professional',
    label: 'Professional',
    description: 'Writing is my craft',
    icon: CupertinoIcons.star_fill,
  ),
];

const kGoalOptions = <PreferenceOption>[
  PreferenceOption(
    value: 'self_expression',
    label: 'Express myself',
    icon: CupertinoIcons.bubble_left,
  ),
  PreferenceOption(
    value: 'audience',
    label: 'Build an audience',
    icon: CupertinoIcons.person_2,
  ),
  PreferenceOption(
    value: 'craft',
    label: 'Hone my craft',
    icon: CupertinoIcons.wand_stars,
  ),
  PreferenceOption(
    value: 'community',
    label: 'Find a community',
    icon: CupertinoIcons.group,
  ),
  PreferenceOption(
    value: 'journal',
    label: 'Journal my life',
    icon: CupertinoIcons.book_circle,
  ),
  PreferenceOption(
    value: 'income',
    label: 'Earn from writing',
    icon: CupertinoIcons.money_dollar_circle,
  ),
  PreferenceOption(
    value: 'inspiration',
    label: 'Find inspiration',
    icon: CupertinoIcons.lightbulb,
  ),
  PreferenceOption(
    value: 'unwind',
    label: 'Unwind & reflect',
    icon: CupertinoIcons.moon_stars,
  ),
];

const kMoodOptions = <PreferenceOption>[
  PreferenceOption(value: 'introspective', label: 'Introspective', icon: CupertinoIcons.cloud_moon),
  PreferenceOption(value: 'uplifting', label: 'Uplifting', icon: CupertinoIcons.sun_max),
  PreferenceOption(value: 'humorous', label: 'Humorous', icon: CupertinoIcons.smiley),
  PreferenceOption(value: 'dark', label: 'Dark & moody', icon: CupertinoIcons.moon),
  PreferenceOption(value: 'romantic', label: 'Romantic', icon: CupertinoIcons.heart_circle),
  PreferenceOption(value: 'thoughtful', label: 'Thoughtful', icon: CupertinoIcons.book_circle),
  PreferenceOption(value: 'raw', label: 'Raw & real', icon: CupertinoIcons.flame),
  PreferenceOption(value: 'dreamy', label: 'Dreamy', icon: CupertinoIcons.sparkles),
];

const kFrequencyOptions = <PreferenceOption>[
  PreferenceOption(value: 'daily', label: 'Daily', description: 'Writing is a ritual'),
  PreferenceOption(value: 'weekly', label: 'Weekly', description: 'A few times a week'),
  PreferenceOption(value: 'monthly', label: 'Monthly', description: 'When the muse calls'),
  PreferenceOption(value: 'occasionally', label: 'Occasionally', description: 'Just here to explore'),
];

const kLengthOptions = <PreferenceOption>[
  PreferenceOption(value: 'short', label: 'Short', description: 'Under 5 min reads'),
  PreferenceOption(value: 'medium', label: 'Medium', description: '5 – 15 min reads'),
  PreferenceOption(value: 'long', label: 'Long', description: 'Deep, immersive pieces'),
  PreferenceOption(value: 'mixed', label: 'A mix', description: 'Surprise me'),
];
