/// Onboarding and feed preference data stored in Firestore.
class UserPreferences {
  final List<String> preferredGenres;
  final List<String> preferredWritingTypes;
  final List<String> interests;

  const UserPreferences({
    this.preferredGenres = const [],
    this.preferredWritingTypes = const [],
    this.interests = const [],
  });

  factory UserPreferences.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const UserPreferences();
    return UserPreferences(
      preferredGenres: List<String>.from(json['preferredGenres'] ?? []),
      preferredWritingTypes:
          List<String>.from(json['preferredWritingTypes'] ?? []),
      interests: List<String>.from(json['interests'] ?? []),
    );
  }

  Map<String, dynamic> toJson() => {
        'preferredGenres': preferredGenres,
        'preferredWritingTypes': preferredWritingTypes,
        'interests': interests,
      };

  UserPreferences copyWith({
    List<String>? preferredGenres,
    List<String>? preferredWritingTypes,
    List<String>? interests,
  }) =>
      UserPreferences(
        preferredGenres: preferredGenres ?? this.preferredGenres,
        preferredWritingTypes:
            preferredWritingTypes ?? this.preferredWritingTypes,
        interests: interests ?? this.interests,
      );
}
