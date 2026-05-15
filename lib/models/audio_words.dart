import 'dart:convert';

/// One word from a faster-whisper alignment, with its on-screen text
/// and its time range inside the chapter's MP3.
class TimedWord {
  /// The word as the whisper tokenizer surfaced it. Includes attached
  /// punctuation ("Rabbit-Hole.", "I,") because whisper keeps it
  /// glued to the preceding token — the rendering layer cleans up.
  final String word;

  /// Inclusive start time in seconds.
  final double startSeconds;

  /// Inclusive end time in seconds. May briefly precede the *next*
  /// word's start in dense passages (faster-whisper artefact); the
  /// reader's word-finder always picks the latest word whose start
  /// is `<=` the position, so ordering wins over end-time precision.
  final double endSeconds;

  const TimedWord({
    required this.word,
    required this.startSeconds,
    required this.endSeconds,
  });

  factory TimedWord.fromJson(Map<String, dynamic> json) => TimedWord(
        // Tolerate both the short `w` key from book_ingest.tts_synth's
        // alignment writer and the long `word` key from raw
        // faster-whisper output, in case anyone ever feeds the latter
        // through.
        word: ((json['w'] ?? json['word']) as String? ?? '').trim(),
        startSeconds: (json['start'] as num?)?.toDouble() ?? 0.0,
        endSeconds: (json['end'] as num?)?.toDouble() ?? 0.0,
      );
}

/// The whole `<chapter>.words.json` file, in memory.
///
/// Schema produced by `book_ingest.align_pass`:
/// ```json
/// {
///   "wav": "01_chapter-i-...wav",
///   "duration": 676.844,
///   "words": [{"w": "Chapter", "start": 0.0, "end": 0.84}, ...]
/// }
/// ```
class AudioWords {
  /// All words in playback order. Empty list when the words.json
  /// couldn't be fetched — the player still works, just without
  /// per-word highlighting.
  final List<TimedWord> words;

  /// Total chapter duration in seconds, from the `duration` field.
  /// Used to validate scrubber bounds and as a fallback when the
  /// player's `duration` stream hasn't ticked yet.
  final double durationSeconds;

  const AudioWords({required this.words, required this.durationSeconds});

  static const AudioWords empty = AudioWords(words: [], durationSeconds: 0.0);

  factory AudioWords.fromJson(Map<String, dynamic> json) {
    final raw = json['words'];
    final List<TimedWord> parsed = (raw is List)
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(TimedWord.fromJson)
            .where((w) => w.word.isNotEmpty)
            .toList(growable: false)
        : const [];
    final dur = (json['duration'] as num?)?.toDouble() ?? 0.0;
    return AudioWords(words: parsed, durationSeconds: dur);
  }

  factory AudioWords.fromJsonString(String s) {
    final decoded = jsonDecode(s);
    if (decoded is Map<String, dynamic>) return AudioWords.fromJson(decoded);
    return AudioWords.empty;
  }

  /// Index of the word whose time range contains [positionSeconds].
  ///
  /// Uses binary search on the (sorted, non-overlapping-in-start)
  /// `words` list — O(log N) per call so we can run it on every audio
  /// position tick (~30 Hz) without burning frame budget on big books.
  /// Returns -1 before the first word and `words.length - 1` after
  /// the last so the highlight sticks on the final word instead of
  /// snapping away during the trailing silence.
  int wordIndexAt(double positionSeconds) {
    if (words.isEmpty) return -1;
    if (positionSeconds < words.first.startSeconds) return -1;
    if (positionSeconds >= words.last.startSeconds) return words.length - 1;
    int lo = 0;
    int hi = words.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (words[mid].startSeconds <= positionSeconds) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }
}
