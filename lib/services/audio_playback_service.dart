import 'dart:async';
import 'dart:convert';

import 'package:audio_session/audio_session.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:rxdart/rxdart.dart';

import 'package:inkspacex/models/audio_words.dart';
import 'package:inkspacex/models/feed_item_model.dart';

/// One book worth of audio data routed through the player.
///
/// Each chapter that has audio becomes one `IndexedAudioSource` in a
/// `ConcatenatingAudioSource`, so prev/next/skip behave correctly and
/// the lock-screen "Up Next" works without any extra plumbing.
class AudioBookContext {
  final FeedItemModel book;

  /// All chapters in publish order. Chapters without audio are kept
  /// in the list (so chapter indices align with the reader's chapter
  /// list) but aren't fed into the player's queue.
  final List<FeedItemSection> chapters;

  /// Index into [chapters] for the chapter that is currently loaded
  /// in the player. Updated whenever the queue advances.
  int currentChapterIndex;

  AudioBookContext({
    required this.book,
    required this.chapters,
    this.currentChapterIndex = 0,
  });

  /// Returns the chapters that actually have audio, paired with their
  /// real index inside [chapters].
  List<({int realIndex, FeedItemSection section})> get playable {
    final out = <({int realIndex, FeedItemSection section})>[];
    for (var i = 0; i < chapters.length; i++) {
      if (chapters[i].hasAudio) out.add((realIndex: i, section: chapters[i]));
    }
    return out;
  }
}

/// One chapter's resume position — written every few seconds while
/// the user listens, so a kill-and-relaunch picks back up where they
/// left off (the lock-screen tap path also relies on this).
class PlaybackResumeState {
  final String bookId;
  final String sectionId;
  final double positionSeconds;
  final double speed;
  final DateTime updatedAt;

  const PlaybackResumeState({
    required this.bookId,
    required this.sectionId,
    required this.positionSeconds,
    required this.speed,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'sectionId': sectionId,
        'positionSeconds': positionSeconds,
        'speed': speed,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory PlaybackResumeState.fromJson(Map<String, dynamic> json) =>
      PlaybackResumeState(
        bookId: json['bookId'] as String? ?? '',
        sectionId: json['sectionId'] as String? ?? '',
        positionSeconds: (json['positionSeconds'] as num?)?.toDouble() ?? 0.0,
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// One singleton wraps the audiobook player.
///
/// Why a singleton: the lock-screen MediaItem and the Now Playing
/// session are *process-global*. Two AudioPlayer instances fighting
/// over them produces flicker and double-control bugs on iOS. The
/// app instantiates this once in `main.dart` (after
/// `JustAudioBackground.init`) and every screen reads from it.
class AudioPlaybackService {
  AudioPlaybackService._();
  static final AudioPlaybackService instance = AudioPlaybackService._();

  static const String _resumeBoxName = 'audio_last_played';
  static const String _resumeKey = 'last';
  static const String _wordsCacheBoxName = 'audio_words_cache';

  final AudioPlayer _player = AudioPlayer();
  AudioBookContext? _ctx;

  /// Per-chapter words.json. Lazily fetched on first listen, kept
  /// alive for the lifetime of the current book context.
  final Map<String, AudioWords> _wordsCache = {};

  /// Stream of the active chapter's word index (or -1 if before the
  /// first word). Recomputed from the position stream every tick.
  ///
  /// The reader's `HighlightedChapterText` listens to this directly;
  /// the AudioPlayerPage uses it to scroll the lyric-style view.
  final BehaviorSubject<int> currentWordIndex = BehaviorSubject.seeded(-1);

  /// Loaded words for the chapter currently in the player.
  final BehaviorSubject<AudioWords> currentWords =
      BehaviorSubject.seeded(AudioWords.empty);

  /// Hive box created lazily so the service can be instantiated
  /// before `Hive.initFlutter()` has run (we always init Hive in
  /// `main()` before `runApp`, so by the time the first `play()` is
  /// called the box is openable).
  Box? _resumeBox;
  Box? _wordsCacheBox;
  Timer? _persistTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlayerState>? _stateSub;

  /// Streams exposed to the UI layer (re-exported so widgets don't
  /// import just_audio directly — keeps swap-out cheap if we ever
  /// move to media_kit or back to a custom platform channel).
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<bool> get playingStream => _player.playingStream;
  Stream<double> get speedStream => _player.speedStream;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;

  Duration get position => _player.position;
  Duration? get duration => _player.duration;
  bool get playing => _player.playing;
  double get speed => _player.speed;
  AudioBookContext? get context => _ctx;

  /// Called from `main()` after `Hive.initFlutter()` + `JustAudioBackground.init`.
  Future<void> bootstrap() async {
    _resumeBox = await Hive.openBox(_resumeBoxName);
    _wordsCacheBox = await Hive.openBox(_wordsCacheBoxName);
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.speech());

    // Position → current-word index. Runs on every position tick
    // (just_audio emits at ~30 Hz; cheap because wordIndexAt is
    // O(log N)).
    _positionSub = _player.positionStream.listen((pos) {
      final words = currentWords.value;
      if (words.words.isEmpty) {
        currentWordIndex.add(-1);
        return;
      }
      final i = words.wordIndexAt(pos.inMilliseconds / 1000.0);
      if (i != currentWordIndex.value) currentWordIndex.add(i);
    });

    // Index transitions = chapter change. Reload words.json for the
    // new chapter so highlighting follows the audio.
    _indexSub = _player.currentIndexStream.listen((i) async {
      if (i == null) return;
      final ctx = _ctx;
      if (ctx == null) return;
      final playable = ctx.playable;
      if (i < 0 || i >= playable.length) return;
      ctx.currentChapterIndex = playable[i].realIndex;
      await _loadWordsFor(playable[i].section);
    });

    // Persist position every 5 s while playing.
    _stateSub = _player.playerStateStream.listen((s) {
      if (s.playing) {
        _persistTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
          _persistResume();
        });
      } else {
        _persistTimer?.cancel();
        _persistTimer = null;
        // One final persist on pause/stop so a foreground→backgrounded
        // app doesn't lose the last few seconds.
        _persistResume();
      }
    });
  }

  /// Load a book into the player and (optionally) start playback at
  /// [startSectionId] / [startPositionSeconds].
  ///
  /// If [startSectionId] is null, the saved resume state for this
  /// book is used; if there isn't one, playback starts at the first
  /// audio chapter.
  Future<void> loadBook(
    FeedItemModel book, {
    String? startSectionId,
    double? startPositionSeconds,
    bool autoPlay = false,
  }) async {
    final ctx = AudioBookContext(book: book, chapters: book.sections);
    _ctx = ctx;

    final playable = ctx.playable;
    if (playable.isEmpty) {
      // Nothing to play — clear and bail.
      await _player.stop();
      currentWords.add(AudioWords.empty);
      currentWordIndex.add(-1);
      return;
    }

    // Build the queue. Each chapter becomes a tagged audio source so
    // just_audio_background can render its title on the lock screen.
    final coverArt = book.coverImageUrl?.isNotEmpty == true
        ? book.coverImageUrl!
        : (book.imageUrl.isNotEmpty ? book.imageUrl : null);
    final sources = playable.map((entry) {
      final s = entry.section;
      return AudioSource.uri(
        Uri.parse(s.audioUrl!),
        tag: MediaItem(
          id: '${book.id}/${s.id}',
          album: book.title,
          title: s.title.isEmpty ? 'Chapter' : s.title,
          artist: book.author,
          artUri: coverArt != null ? Uri.tryParse(coverArt) : null,
          duration: s.audioDurationSeconds == null
              ? null
              : Duration(milliseconds: (s.audioDurationSeconds! * 1000).round()),
          extras: {
            'bookId': book.id,
            'sectionId': s.id,
            'wordsUrl': s.audioWordsUrl,
          },
        ),
      );
    }).toList();

    // Resolve start position. Order: explicit args → saved resume
    // for this book → first chapter at 0.
    String? targetSectionId = startSectionId;
    double targetSeconds = startPositionSeconds ?? 0.0;
    if (targetSectionId == null) {
      final saved = readResume();
      if (saved != null && saved.bookId == book.id) {
        targetSectionId = saved.sectionId;
        targetSeconds = saved.positionSeconds;
      }
    }
    int initialIndex = 0;
    for (var i = 0; i < playable.length; i++) {
      if (playable[i].section.id == targetSectionId) {
        initialIndex = i;
        break;
      }
    }

    await _player.setAudioSource(
      ConcatenatingAudioSource(children: sources),
      initialIndex: initialIndex,
      initialPosition: Duration(milliseconds: (targetSeconds * 1000).round()),
    );
    ctx.currentChapterIndex = playable[initialIndex].realIndex;
    await _loadWordsFor(playable[initialIndex].section);

    if (autoPlay) await _player.play();
  }

  Future<void> _loadWordsFor(FeedItemSection section) async {
    if (!section.hasAudio) {
      currentWords.add(AudioWords.empty);
      return;
    }
    final cached = _wordsCache[section.id];
    if (cached != null) {
      currentWords.add(cached);
      return;
    }
    // On-disk cache (Hive) so repeat plays don't refetch.
    final hiveHit = _wordsCacheBox?.get(section.id) as String?;
    if (hiveHit != null) {
      final parsed = AudioWords.fromJsonString(hiveHit);
      _wordsCache[section.id] = parsed;
      currentWords.add(parsed);
      return;
    }
    final url = section.audioWordsUrl;
    if (url == null || url.isEmpty) {
      currentWords.add(AudioWords.empty);
      return;
    }
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final parsed = AudioWords.fromJsonString(resp.body);
        _wordsCache[section.id] = parsed;
        await _wordsCacheBox?.put(section.id, resp.body);
        currentWords.add(parsed);
      } else {
        currentWords.add(AudioWords.empty);
      }
    } catch (_) {
      currentWords.add(AudioWords.empty);
    }
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> togglePlayPause() =>
      _player.playing ? _player.pause() : _player.play();

  /// Drop the loaded book from RAM. Persists the resume position
  /// first (so a later loadBook(book) jumps right back to where the
  /// listener left off via the Hive `audio_last_played` box) then
  /// stops the player and clears the in-memory audio source. Used
  /// when the listener navigates to a different book's reader — the
  /// previous book's MP3 + words.json shouldn't keep eating RAM
  /// while they're reading something else.
  Future<void> clear() async {
    if (_ctx == null) return;
    _persistResume();
    _persistTimer?.cancel();
    _persistTimer = null;
    await _player.stop();
    // setAudioSource with an empty Concatenating source releases the
    // current track. just_audio doesn't expose a "release" verb but
    // an empty source effectively unloads the previous one.
    try {
      await _player.setAudioSource(ConcatenatingAudioSource(children: []));
    } catch (_) {
      // setAudioSource on web sometimes throws when given an empty
      // concat source; the stop() above is enough to free RAM.
    }
    _ctx = null;
    currentWords.add(AudioWords.empty);
    currentWordIndex.add(-1);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    final words = currentWords.value;
    if (words.words.isNotEmpty) {
      currentWordIndex.add(
        words.wordIndexAt(position.inMilliseconds / 1000.0),
      );
    }
  }

  Future<void> skipForward({Duration by = const Duration(seconds: 15)}) =>
      seek(_player.position + by);
  Future<void> skipBackward({Duration by = const Duration(seconds: 15)}) =>
      seek(Duration(
        milliseconds:
            (_player.position - by).inMilliseconds.clamp(0, 1 << 31),
      ));

  Future<void> nextChapter() => _player.seekToNext();
  Future<void> previousChapter() => _player.seekToPrevious();
  Future<void> jumpToChapterIndex(int realChapterIndex) async {
    final ctx = _ctx;
    if (ctx == null) return;
    final playable = ctx.playable;
    for (var i = 0; i < playable.length; i++) {
      if (playable[i].realIndex == realChapterIndex) {
        await _player.seek(Duration.zero, index: i);
        return;
      }
    }
  }

  /// Step set: 0.75 / 1.0 / 1.25 / 1.5 / 2.0. Anything outside is
  /// clamped — `just_audio` accepts arbitrary floats but the UI
  /// surfaces only these presets, and the audio quality stays
  /// natural across this range without re-tuning the pitch.
  Future<void> setSpeed(double speed) =>
      _player.setSpeed(speed.clamp(0.5, 2.5));

  /// Read back the last persisted position. Null when nothing was
  /// ever saved (first run) or the Hive box isn't open yet.
  PlaybackResumeState? readResume() {
    final box = _resumeBox;
    if (box == null) return null;
    final raw = box.get(_resumeKey);
    if (raw is String) {
      try {
        return PlaybackResumeState.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  void _persistResume() {
    final ctx = _ctx;
    if (ctx == null) return;
    final playable = ctx.playable;
    final i = _player.currentIndex ?? 0;
    if (i < 0 || i >= playable.length) return;
    final section = playable[i].section;
    final state = PlaybackResumeState(
      bookId: ctx.book.id,
      sectionId: section.id,
      positionSeconds: _player.position.inMilliseconds / 1000.0,
      speed: _player.speed,
      updatedAt: DateTime.now(),
    );
    _resumeBox?.put(_resumeKey, jsonEncode(state.toJson()));
  }

  Future<void> dispose() async {
    await _positionSub?.cancel();
    await _indexSub?.cancel();
    await _stateSub?.cancel();
    _persistTimer?.cancel();
    await _player.dispose();
  }
}
