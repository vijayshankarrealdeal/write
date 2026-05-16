import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'package:inkspacex/models/audio_words.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/services/audio_playback_service.dart';

/// The dedicated "now playing" view — cover art + scrolling lyric-style
/// word-highlighted text + controls.
///
/// Layout is responsive: side-by-side on wide screens (macOS / web /
/// landscape iPad), stacked on tall ones (phones, portrait tablets).
/// The cover is the big square; the active word uses the page's
/// foreground colour, the rest fade. Auto-scrolls so the active word
/// lands at the viewport's upper-third — leaves a strip of already-
/// read context above and lots of lookahead below. The scroll target
/// is the word's *measured* y-position (via TextPainter) rather than
/// a proportional estimate; the estimate drifted badly on long
/// chapters because word density isn't uniform across paragraphs.
/// Light/dark register is driven by `AudioPlaybackService.uiBrightness`
/// — set by the reader so the listen experience matches the page the
/// user was on.
class AudioPlayerPage extends StatefulWidget {
  const AudioPlayerPage({super.key});

  @override
  State<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

/// Resolved colours for the audio surfaces in the active brightness.
class _AudioPalette {
  final Color bg;
  final Color fg;
  final Color readWord;
  final Color unreadWord;
  final Color subtle;
  final Color menuSurface;
  const _AudioPalette({
    required this.bg,
    required this.fg,
    required this.readWord,
    required this.unreadWord,
    required this.subtle,
    required this.menuSurface,
  });

  factory _AudioPalette.of(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return _AudioPalette(
        bg: const Color(0xFF000000),
        fg: const Color(0xFFFFFFFF),
        readWord: Colors.white.withOpacity(0.85),
        unreadWord: Colors.white.withOpacity(0.32),
        subtle: Colors.white.withOpacity(0.6),
        menuSurface: Colors.grey.shade900,
      );
    }
    return _AudioPalette(
      bg: const Color(0xFFFFFFFF),
      fg: const Color(0xFF1A1A1A),
      readWord: const Color(0xFF1A1A1A).withOpacity(0.85),
      unreadWord: const Color(0xFF1A1A1A).withOpacity(0.32),
      subtle: const Color(0xFF1A1A1A).withOpacity(0.6),
      menuSurface: const Color(0xFFF1F5F9),
    );
  }
}

class _AudioPlayerPageState extends State<AudioPlayerPage> {
  final AudioPlaybackService _audio = AudioPlaybackService.instance;
  final ScrollController _scrollController = ScrollController();
  // Each TimedWord gets a GlobalKey so we can compute its position
  // inside the scroll view and centre it on tick. Built lazily because
  // a long chapter can have ~3000 words and reallocating the list on
  // every frame is wasteful.
  // Tap-gesture recognisers — one per word in the loaded chapter.
  // Cached because building 3000 fresh recognizer objects on every
  // position tick was the dominant cost on Flutter web mobile, and
  // because a TextSpan.recognizer expects a stable object.
  final List<TapGestureRecognizer> _wordRecognizers = [];
  AudioWords _lastWords = AudioWords.empty;
  int _lastScrolledIndex = -1;
  // Set when the user taps a word. The position-tick that follows
  // the resulting seek would otherwise scroll the page to centre the
  // tapped word — but the user's eye is already on it, so the scroll
  // looks like a pointless jolt. Cleared after we consume one tick.
  bool _suppressNextScroll = false;

  // Measured y-position (text-local coords) of each word's line top.
  // Populated by _ensureWordYOffsets via a one-off TextPainter layout
  // matching the on-screen Text.rich. The scroll target for word i is
  // _wordYOffsets[i] — placing the line at the viewport's upper-third
  // because the SingleChildScrollView pads top by viewportH/3. Keyed
  // on (words identity, layout width) so a different chapter or a
  // resize triggers a fresh measurement; otherwise we reuse.
  List<double> _wordYOffsets = const [];
  double _wordYOffsetsWidth = 0;
  AudioWords _wordYOffsetsWords = AudioWords.empty;

  @override
  void dispose() {
    for (final r in _wordRecognizers) {
      r.dispose();
    }
    _wordRecognizers.clear();
    _scrollController.dispose();
    super.dispose();
  }

  /// Rebuild the cached per-word recognizers when the chapter changes.
  /// Each recognizer wires onTap to `audio.seek(...)` for that word's
  /// start timestamp; the recognizer object itself is reused across
  /// position-tick rebuilds so we don't churn the GC.
  void _rebuildWordRecognizers(AudioWords words) {
    if (identical(words, _lastWords)) return;
    _lastWords = words;
    for (final r in _wordRecognizers) {
      r.dispose();
    }
    _wordRecognizers
      ..clear()
      ..addAll(
        List.generate(
          words.words.length,
          (i) => TapGestureRecognizer()
            ..onTap = () {
              _suppressNextScroll = true;
              _audio.seek(Duration(
                milliseconds: (words.words[i].startSeconds * 1000).round(),
              ));
            },
        ),
      );
    _lastScrolledIndex = -1;
  }

  /// Measure each word's line-top y-position in the laid-out text so
  /// _maybeScrollTo can target the actual position instead of a
  /// proportional estimate. The estimate was correct on average but
  /// drifted line-by-line because word density varies: dialogue
  /// paragraphs pack fewer words per line than dense descriptive
  /// prose, so a seek to "halfway through the words" landed nowhere
  /// near the halfway point of the rendered text.
  ///
  /// Done with a single off-screen TextPainter layout at the matching
  /// width and base style; results are cached per (words, width).
  /// Active-word weight (w700) differs from base (w500) but only one
  /// word at a time is bold, so line-wrap shifts are sub-pixel — the
  /// difference is invisible at upper-third placement scale.
  void _ensureWordYOffsets(AudioWords words, double width, TextStyle style) {
    if (identical(words, _wordYOffsetsWords) &&
        width == _wordYOffsetsWidth) {
      return;
    }
    if (words.words.isEmpty || width <= 0) {
      _wordYOffsets = const [];
      _wordYOffsetsWords = words;
      _wordYOffsetsWidth = width;
      return;
    }

    final buffer = StringBuffer();
    final charStarts = List<int>.filled(words.words.length, 0);
    for (var i = 0; i < words.words.length; i++) {
      charStarts[i] = buffer.length;
      buffer
        ..write(words.words[i].word)
        ..write(' ');
    }

    final tp = TextPainter(
      text: TextSpan(text: buffer.toString(), style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);

    final offsets = List<double>.filled(charStarts.length, 0);
    for (var i = 0; i < charStarts.length; i++) {
      offsets[i] = tp
          .getOffsetForCaret(TextPosition(offset: charStarts[i]), Rect.zero)
          .dy;
    }
    tp.dispose();

    _wordYOffsets = offsets;
    _wordYOffsetsWords = words;
    _wordYOffsetsWidth = width;
  }

  /// Place the active word at the viewport's upper-third — leaves a
  /// strip of just-read context above and a generous lookahead below.
  ///
  /// Geometry: the surrounding LayoutBuilder pads top by viewportH/3
  /// and bottom by 2*viewportH/3, so `maxScrollExtent` equals the
  /// pure text-body height. A scroll-position of `wordY` (text-local
  /// y of the word's line top) therefore places that line at the
  /// viewport's upper-third — the math falls out of the padding.
  ///
  /// For natural progression (one word advancing every few ticks)
  /// the scroll animates smoothly so the eye can follow. For seeks
  /// (scrubber drag, skip buttons, tap-on-word) the new word is
  /// usually far off-screen and we jump instantly — animating a long
  /// distance feels sluggish and loses the user's place.
  void _maybeScrollTo(int index) {
    final total = _lastWords.words.length;
    if (index < 0 || index >= total) return;
    if (index == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    if (_suppressNextScroll) {
      _suppressNextScroll = false;
      _lastScrolledIndex = index;
      return;
    }

    final pos = _scrollController.position;
    final viewportH = pos.viewportDimension;

    final double target;
    if (index < _wordYOffsets.length) {
      target = _wordYOffsets[index].clamp(0.0, pos.maxScrollExtent);
    } else {
      // Pre-measurement fallback. Used for the first frame before
      // _ensureWordYOffsets has had a chance to lay out, or if the
      // index races ahead of a stale cache (different chapter).
      target = (pos.maxScrollExtent * index / math.max(total, 1))
          .clamp(0.0, pos.maxScrollExtent);
    }

    final firstScroll = _lastScrolledIndex < 0;
    final delta = (target - pos.pixels).abs();
    final shouldJump = firstScroll || delta > viewportH * 0.8;

    if (shouldJump) {
      _scrollController.jumpTo(target);
    } else {
      _scrollController
          .animateTo(
            target,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          )
          .catchError((_) {});
    }
    _lastScrolledIndex = index;
  }

  /// Words.json fallback scroll — keeps the page roughly aligned with
  /// audio position when per-word timings are unavailable (older chapter
  /// uploads, fetch failures, text-only review). Without this, the
  /// "Listen" view sat motionless while the audio rolled forward.
  void _maybeScrollFallback(double positionSeconds, double durationSeconds) {
    if (!_scrollController.hasClients) return;
    if (durationSeconds <= 0) return;
    final pos = _scrollController.position;
    final viewportH = pos.viewportDimension;
    final fraction = (positionSeconds / durationSeconds).clamp(0.0, 1.0);
    // Same reasoning as _maybeScrollTo: the LayoutBuilder pads top by
    // viewportH/3 and bottom by 2*viewportH/3, so maxScrollExtent
    // equals the pure body height and `fraction × maxScrollExtent`
    // places that fraction-point of the text at the viewport's
    // upper-third.
    final estimated =
        (pos.maxScrollExtent * fraction).clamp(0.0, pos.maxScrollExtent);
    final firstScroll = _lastScrolledIndex < 0;
    _lastScrolledIndex = 0;
    final delta = (estimated - pos.pixels).abs();
    // Below-threshold deltas still need _lastScrolledIndex flipped above
    // — otherwise the next non-trivial tick re-enters as "first scroll"
    // and jumps instead of animating.
    if (delta < 4) return;
    final shouldJump = firstScroll || delta > viewportH * 0.8;
    if (shouldJump) {
      _scrollController.jumpTo(estimated);
    } else {
      _scrollController
          .animateTo(
            estimated,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          )
          .catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Brightness>(
      valueListenable: _audio.uiBrightness,
      builder: (context, brightness, _) {
        final palette = _AudioPalette.of(brightness);
        final ctx = _audio.context;
        if (ctx == null) {
          return Scaffold(
            backgroundColor: palette.bg,
            appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
            body: Center(
              child: Text(
                'No audio loaded',
                style: TextStyle(color: palette.subtle),
              ),
            ),
          );
        }
        final width = MediaQuery.of(context).size.width;
        final isWide = width > 820;
        return Scaffold(
          backgroundColor: palette.bg,
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: IconThemeData(color: palette.fg),
            leading: IconButton(
              icon: Icon(Icons.close, color: palette.fg),
              onPressed: () => Navigator.of(context).maybePop(),
              tooltip: 'Close',
            ),
            actions: [
              // Speed selector — segmented popup so all common audiobook
              // speeds are one tap away.
              StreamBuilder<double>(
                stream: _audio.speedStream,
                initialData: _audio.speed,
                builder: (context, snap) {
                  final s = snap.data ?? 1.0;
                  return PopupMenuButton<double>(
                    tooltip: 'Playback speed',
                    color: palette.menuSurface,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Center(
                        child: Text(
                          '${s.toStringAsFixed(s == s.roundToDouble() ? 1 : 2)}×',
                          style: TextStyle(
                            color: palette.fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    onSelected: _audio.setSpeed,
                    itemBuilder: (context) => const [0.75, 1.0, 1.25, 1.5, 2.0]
                        .map((speed) => PopupMenuItem(
                              value: speed,
                              child: Text(
                                '${speed.toStringAsFixed(speed == speed.roundToDouble() ? 1 : 2)}×',
                                style: TextStyle(color: palette.fg),
                              ),
                            ))
                        .toList(),
                  );
                },
              ),
            ],
          ),
          body: SafeArea(
            child: isWide
                ? _WideLayout(
                    book: ctx.book,
                    body: _buildLyricsView(palette),
                    audio: _audio,
                    palette: palette,
                  )
                : _NarrowLayout(
                    book: ctx.book,
                    body: _buildLyricsView(palette),
                    audio: _audio,
                    palette: palette,
                  ),
          ),
        );
      },
    );
  }

  Widget _buildLyricsView(_AudioPalette palette) {
    return StreamBuilder<AudioWords>(
      stream: _audio.currentWords,
      initialData: _audio.currentWords.value,
      builder: (context, wordsSnap) {
        final words = wordsSnap.data ?? AudioWords.empty;
        _rebuildWordRecognizers(words);
        if (words.words.isEmpty) {
          // Fall back to the chapter's prose if no word timings —
          // playback still works, but without the karaoke effect.
          // Auto-scroll proportional to audio position so the reader's
          // current spot stays near the centre even without per-word
          // alignment.
          final ctx = _audio.context;
          final fallback = ctx == null
              ? ''
              : (ctx.chapters[ctx.currentChapterIndex].content);
          return StreamBuilder<Duration>(
            stream: _audio.positionStream,
            initialData: _audio.position,
            builder: (context, posSnap) {
              final pos = posSnap.data ?? Duration.zero;
              final durSec = _audio.duration?.inMilliseconds != null
                  ? _audio.duration!.inMilliseconds / 1000.0
                  : 0.0;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _maybeScrollFallback(
                  pos.inMilliseconds / 1000.0,
                  durSec,
                );
              });
              // Pad top by viewportH/3 and bottom by 2*viewportH/3 so
              // the currently-narrated line lands at the viewport's
              // upper-third at any audio position. LayoutBuilder gives
              // the body's real height (after the mini-player +
              // scrubber claim the bottom); MediaQuery would over-pad
              // because the screen is taller than the lyric pane.
              return LayoutBuilder(
                builder: (context, constraints) {
                  final viewportH = constraints.maxHeight;
                  final topPad = viewportH / 3;
                  final bottomPad = viewportH * 2 / 3;
                  return SingleChildScrollView(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(32, topPad, 32, bottomPad),
                    child: Text(
                      fallback.isEmpty
                          ? 'No lyrics available for this chapter.'
                          : fallback,
                      style: TextStyle(
                        color: palette.subtle,
                        fontSize: 20,
                        height: 1.7,
                      ),
                    ),
                  );
                },
              );
            },
          );
        }
        return RepaintBoundary(
          child: StreamBuilder<int>(
            stream: _audio.currentWordIndex,
            initialData: _audio.currentWordIndex.value,
            builder: (context, idxSnap) {
              final activeIndex = idxSnap.data ?? -1;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                _maybeScrollTo(activeIndex);
              });
              return LayoutBuilder(
                builder: (context, constraints) {
                  // Top viewportH/3 + bottom 2*viewportH/3 padding so a
                  // scroll-position equal to a word's text-local y
                  // lands that word at the viewport's upper-third.
                  // See _maybeScrollTo for the geometry.
                  final viewportH = constraints.maxHeight;
                  final topPad = viewportH / 3;
                  final bottomPad = viewportH * 2 / 3;
                  const baseStyle = TextStyle(
                    fontSize: 28,
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  );
                  _ensureWordYOffsets(
                    words,
                    constraints.maxWidth - 64,
                    baseStyle,
                  );
                  return SingleChildScrollView(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(32, topPad, 32, bottomPad),
                    // Plain TextSpan instead of WidgetSpan(Padding(
                    // GestureDetector(Text(...)))) — the old chain
                    // spawned 4 widgets × 3000 words and rebuilt all
                    // of them every 33 ms on Flutter web mobile, which
                    // is what the lag stemmed from. TextSpan +
                    // TapGestureRecognizer is a render-only construct.
                    child: Text.rich(
                      TextSpan(
                        children: [
                          for (var i = 0; i < words.words.length; i++)
                            TextSpan(
                              text: '${words.words[i].word} ',
                              recognizer: i < _wordRecognizers.length
                                  ? _wordRecognizers[i]
                                  : null,
                              style: TextStyle(
                                fontSize: baseStyle.fontSize,
                                height: baseStyle.height,
                                fontWeight: i == activeIndex
                                    ? FontWeight.w700
                                    : baseStyle.fontWeight,
                                color: i == activeIndex
                                    ? palette.fg
                                    : (i < activeIndex
                                        ? palette.readWord
                                        : palette.unreadWord),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }

}

/// Right-of-cover layout used on macOS / web / iPad-landscape.
class _WideLayout extends StatelessWidget {
  final FeedItemModel book;
  final Widget body;
  final AudioPlaybackService audio;
  final _AudioPalette palette;
  const _WideLayout({
    required this.book,
    required this.body,
    required this.audio,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 5,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(48, 48, 24, 48),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Expanded(child: _CoverArt(book: book)),
                const SizedBox(height: 24),
                _TitleStrip(book: book, audio: audio, palette: palette),
                const SizedBox(height: 8),
                _ScrubberControls(audio: audio, palette: palette),
              ],
            ),
          ),
        ),
        Expanded(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 64, 48, 48),
            child: body,
          ),
        ),
      ],
    );
  }
}

/// Stacked layout used on phones. Reading-first: the lyric pane gets
/// the whole upper area; the cover shrinks into a circular avatar
/// beside the chapter title at the bottom (Spotify "now playing"
/// pattern), and the scrubber/transport sits beneath.
class _NarrowLayout extends StatelessWidget {
  final FeedItemModel book;
  final Widget body;
  final AudioPlaybackService audio;
  final _AudioPalette palette;
  const _NarrowLayout({
    required this.book,
    required this.body,
    required this.audio,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: body),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: _MiniNowPlaying(book: book, audio: audio, palette: palette),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: _ScrubberControls(audio: audio, palette: palette),
        ),
      ],
    );
  }
}

/// Compact "what's playing" strip — circular cover avatar on the
/// left, chapter title + author stacked on the right. Used inside
/// the narrow layout's bottom section.
class _MiniNowPlaying extends StatelessWidget {
  final FeedItemModel book;
  final AudioPlaybackService audio;
  final _AudioPalette palette;
  const _MiniNowPlaying({
    required this.book,
    required this.audio,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final url = (book.coverImageUrl?.isNotEmpty == true
            ? book.coverImageUrl!
            : (book.imageUrl.isNotEmpty ? book.imageUrl : ''))
        .trim();
    // Subscribe to the player's current-index stream so the chapter
    // title in the strip updates when the user hits prev/next or auto-
    // advances. Reading audio.context at build time was a snapshot — it
    // never refreshed, so users always saw "Chapter I" no matter where
    // they were.
    return StreamBuilder<int?>(
      stream: audio.currentIndexStream,
      initialData: audio.context?.currentChapterIndex,
      builder: (context, _) {
        final ctx = audio.context;
        final chapterTitle = (ctx == null ||
                ctx.currentChapterIndex < 0 ||
                ctx.currentChapterIndex >= ctx.chapters.length)
            ? ''
            : ctx.chapters[ctx.currentChapterIndex].title;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipOval(
              child: SizedBox(
                width: 56,
                height: 56,
                child: url.isEmpty
                    ? Container(color: Colors.grey.shade800)
                    : CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        placeholder: (_, __) =>
                            Container(color: Colors.grey.shade900),
                        errorWidget: (_, __, ___) =>
                            Container(color: Colors.grey.shade800),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chapterTitle.isEmpty ? book.title : chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.fg,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    chapterTitle.isEmpty
                        ? book.author
                        : '${book.author} — ${book.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.subtle,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CoverArt extends StatelessWidget {
  final FeedItemModel book;
  const _CoverArt({required this.book});

  @override
  Widget build(BuildContext context) {
    final url = (book.coverImageUrl?.isNotEmpty == true
            ? book.coverImageUrl!
            : (book.imageUrl.isNotEmpty ? book.imageUrl : ''))
        .trim();
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 32,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 1,
          child: url.isEmpty
              ? Container(color: Colors.grey.shade800)
              : CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(color: Colors.grey.shade900),
                  errorWidget: (_, __, ___) => Container(color: Colors.grey.shade800),
                ),
        ),
      ),
    );
  }
}

class _TitleStrip extends StatelessWidget {
  final FeedItemModel book;
  final AudioPlaybackService audio;
  final _AudioPalette palette;
  const _TitleStrip({
    required this.book,
    required this.audio,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    // Same reasoning as _MiniNowPlaying: reading audio.context at build
    // time was a snapshot, so the chapter title never refreshed on
    // prev/next or auto-advance. Subscribe to the index stream.
    return StreamBuilder<int?>(
      stream: audio.currentIndexStream,
      initialData: audio.context?.currentChapterIndex,
      builder: (context, _) {
        final ctx = audio.context;
        final chapterTitle = (ctx == null ||
                ctx.currentChapterIndex < 0 ||
                ctx.currentChapterIndex >= ctx.chapters.length)
            ? ''
            : ctx.chapters[ctx.currentChapterIndex].title;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                chapterTitle.isEmpty ? book.title : chapterTitle,
                style: TextStyle(
                  color: palette.fg,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                chapterTitle.isEmpty
                    ? book.author
                    : '${book.author} — ${book.title}',
                style: TextStyle(
                  color: palette.fg.withOpacity(0.7),
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Scrubber + main transport controls. Encapsulated so both the wide
/// and narrow layouts use the exact same widget tree.
class _ScrubberControls extends StatelessWidget {
  final AudioPlaybackService audio;
  final _AudioPalette palette;
  const _ScrubberControls({required this.audio, required this.palette});

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: audio.durationStream,
      builder: (context, durSnap) {
        final dur = durSnap.data ?? Duration.zero;
        return StreamBuilder<Duration>(
          stream: audio.positionStream,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final clampedMax = math.max(dur.inMilliseconds, 1).toDouble();
            final clampedPos =
                pos.inMilliseconds.clamp(0, clampedMax.toInt()).toDouble();
            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: palette.fg,
                    inactiveTrackColor: palette.fg.withOpacity(0.18),
                    thumbColor: palette.fg,
                  ),
                  child: _SeekSlider(
                    min: 0,
                    max: clampedMax,
                    livePos: clampedPos,
                    onSeek: (ms) => audio.seek(Duration(milliseconds: ms)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(pos),
                          style: TextStyle(color: palette.subtle)),
                      Text(
                        dur == Duration.zero
                            ? '--:--'
                            : '-${_fmt(dur - pos)}',
                        style: TextStyle(color: palette.subtle),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: Icon(Icons.skip_previous, color: palette.fg, size: 28),
                      onPressed: audio.previousChapter,
                      tooltip: 'Previous chapter',
                    ),
                    IconButton(
                      icon: Icon(Icons.replay_10, color: palette.fg, size: 28),
                      onPressed: () =>
                          audio.skipBackward(by: const Duration(seconds: 10)),
                      tooltip: 'Back 10s',
                    ),
                    StreamBuilder<PlayerState>(
                      stream: audio.playerStateStream,
                      builder: (context, snap) {
                        final state = snap.data;
                        final playing = state?.playing == true;
                        final loading = state?.processingState ==
                                ProcessingState.loading ||
                            state?.processingState ==
                                ProcessingState.buffering;
                        return IconButton(
                          iconSize: 56,
                          icon: loading
                              ? SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(
                                    color: palette.fg,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Icon(
                                  playing
                                      ? Icons.pause_circle_filled
                                      : Icons.play_circle_fill,
                                  color: palette.fg,
                                  size: 56,
                                ),
                          onPressed: loading ? null : audio.togglePlayPause,
                        );
                      },
                    ),
                    IconButton(
                      icon: Icon(Icons.forward_30, color: palette.fg, size: 28),
                      onPressed: () =>
                          audio.skipForward(by: const Duration(seconds: 30)),
                      tooltip: 'Forward 30s',
                    ),
                    IconButton(
                      icon: Icon(Icons.skip_next, color: palette.fg, size: 28),
                      onPressed: audio.nextChapter,
                      tooltip: 'Next chapter',
                    ),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Seek slider that lets the user drag freely without firing a seek
/// per pixel. While the thumb is held the value lives in local state;
/// only `onChangeEnd` commits the seek to the AudioPlaybackService.
/// Without this, dragging across a 16-hour book triggered hundreds of
/// `seek()` calls per second, each restarting the audio buffer.
class _SeekSlider extends StatefulWidget {
  final double min;
  final double max;
  final double livePos;
  final ValueChanged<int> onSeek;
  const _SeekSlider({
    required this.min,
    required this.max,
    required this.livePos,
    required this.onSeek,
  });

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final value = (_dragValue ?? widget.livePos).clamp(widget.min, widget.max);
    return Slider(
      min: widget.min,
      max: widget.max,
      value: value,
      onChanged: (v) => setState(() => _dragValue = v),
      onChangeEnd: (v) {
        widget.onSeek(v.round());
        setState(() => _dragValue = null);
      },
    );
  }
}
