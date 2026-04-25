/// Onboarding and feed preference data stored in Firestore.
class UserPreferences {
  final List<String> preferredGenres;
  final List<String> preferredWritingTypes;
  final List<String> interests;

  /// Primary role: 'writer' | 'reader' | 'both'.
  final String? primaryRole;

  /// Self-reported experience level:
  /// 'beginner' | 'hobbyist' | 'experienced' | 'professional'.
  final String? experienceLevel;

  /// What brought the user to the app (multi-select).
  /// e.g. 'self_expression', 'audience', 'craft', 'income', 'community', 'journal'.
  final List<String> goals;

  /// Tonal preferences for curation (multi-select).
  /// e.g. 'introspective', 'uplifting', 'dark', 'humorous', 'romantic', 'thoughtful'.
  final List<String> moodThemes;

  /// How often the user writes: 'daily' | 'weekly' | 'monthly' | 'occasionally'.
  final String? writingFrequency;

  /// Preferred reading length: 'short' | 'medium' | 'long' | 'mixed'.
  final String? contentLengthPreference;

  const UserPreferences({
    this.preferredGenres = const [],
    this.preferredWritingTypes = const [],
    this.interests = const [],
    this.primaryRole,
    this.experienceLevel,
    this.goals = const [],
    this.moodThemes = const [],
    this.writingFrequency,
    this.contentLengthPreference,
  });

  factory UserPreferences.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UserPreferences();
    return UserPreferences(
      preferredGenres: List<String>.from(json['preferredGenres'] ?? []),
      preferredWritingTypes:
          List<String>.from(json['preferredWritingTypes'] ?? []),
      interests: List<String>.from(json['interests'] ?? []),
      primaryRole: json['primaryRole'] as String?,
      experienceLevel: json['experienceLevel'] as String?,
      goals: List<String>.from(json['goals'] ?? []),
      moodThemes: List<String>.from(json['moodThemes'] ?? []),
      writingFrequency: json['writingFrequency'] as String?,
      contentLengthPreference: json['contentLengthPreference'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'preferredGenres': preferredGenres,
        'preferredWritingTypes': preferredWritingTypes,
        'interests': interests,
        'primaryRole': primaryRole,
        'experienceLevel': experienceLevel,
        'goals': goals,
        'moodThemes': moodThemes,
        'writingFrequency': writingFrequency,
        'contentLengthPreference': contentLengthPreference,
      };

  UserPreferences copyWith({
    List<String>? preferredGenres,
    List<String>? preferredWritingTypes,
    List<String>? interests,
    String? primaryRole,
    String? experienceLevel,
    List<String>? goals,
    List<String>? moodThemes,
    String? writingFrequency,
    String? contentLengthPreference,
  }) =>
      UserPreferences(
        preferredGenres: preferredGenres ?? this.preferredGenres,
        preferredWritingTypes:
            preferredWritingTypes ?? this.preferredWritingTypes,
        interests: interests ?? this.interests,
        primaryRole: primaryRole ?? this.primaryRole,
        experienceLevel: experienceLevel ?? this.experienceLevel,
        goals: goals ?? this.goals,
        moodThemes: moodThemes ?? this.moodThemes,
        writingFrequency: writingFrequency ?? this.writingFrequency,
        contentLengthPreference:
            contentLengthPreference ?? this.contentLengthPreference,
      );
}
