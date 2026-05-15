import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
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
/// The cover is the big square; the active word is bright white, the
/// rest dim grey. Auto-scrolls to keep the active word near the
/// vertical centre.
class AudioPlayerPage extends StatefulWidget {
  const AudioPlayerPage({super.key});

  @override
  State<AudioPlayerPage> createState() => _AudioPlayerPageState();
}

class _AudioPlayerPageState extends State<AudioPlayerPage> {
  final AudioPlaybackService _audio = AudioPlaybackService.instance;
  final ScrollController _scrollController = ScrollController();
  // Each TimedWord gets a GlobalKey so we can compute its position
  // inside the scroll view and centre it on tick. Built lazily because
  // a long chapter can have ~3000 words and reallocating the list on
  // every frame is wasteful.
  final List<GlobalKey> _wordKeys = [];
  AudioWords _lastWords = AudioWords.empty;
  int _lastScrolledIndex = -1;
  // Set when the user taps a word. The position-tick that follows
  // the resulting seek would otherwise scroll the page to centre the
  // tapped word — but the user's eye is already on it, so the scroll
  // looks like a pointless jolt. Cleared after we consume one tick.
  bool _suppressNextScroll = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _rebuildWordKeys(AudioWords words) {
    if (identical(words, _lastWords)) return;
    _lastWords = words;
    _wordKeys
      ..clear()
      ..addAll(List.generate(words.words.length, (_) => GlobalKey()));
    _lastScrolledIndex = -1;
  }

  /// Keep the active word near 40% from the top of the viewport.
  ///
  /// Two cases to handle separately:
  ///   - **Small step (regular playback tick).** The new word is on
  ///     screen, so its GlobalKey resolves. Animate gently.
  ///   - **Big jump (user seeked, scrubbed, or chapter changed).** The
  ///     new word is off-screen, GlobalKey is null. Estimate the
  ///     destination from the index ratio, jump there, then refine
  ///     after one frame once the RenderBox attaches.
  void _maybeScrollTo(int index) {
    if (index < 0 || index >= _wordKeys.length) return;
    if (index == _lastScrolledIndex) return;
    if (!_scrollController.hasClients) return;
    if (_suppressNextScroll) {
      _suppressNextScroll = false;
      _lastScrolledIndex = index;
      return;
    }

    final ctx = _wordKeys[index].currentContext;
    if (ctx == null) {
      // Off-screen — estimate proportionally then refine post-frame.
      final pos = _scrollController.position;
      final total = _wordKeys.length;
      final estimated = (pos.maxScrollExtent * index / math.max(total, 1))
          .clamp(0.0, pos.maxScrollExtent);
      _scrollController.jumpTo(estimated);
      // First scroll after chapter load: snap to the refined position
      // (Duration.zero) instead of animating, so there's no visible
      // bounce on entry. Subsequent jumps animate normally.
      final firstScroll = _lastScrolledIndex < 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx2 = _wordKeys[index].currentContext;
        if (ctx2 != null) {
          Scrollable.ensureVisible(
            ctx2,
            alignment: 0.4,
            duration: firstScroll
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          ).catchError((_) {});
        }
      });
      _lastScrolledIndex = index;
      return;
    }

    // On-screen — only nudge if it's drifting toward an edge.
    final box = ctx.findRenderObject() as RenderBox?;
    final viewport = Scrollable.of(ctx);
    final viewportBox = viewport.context.findRenderObject() as RenderBox?;
    if (box == null || viewportBox == null) return;
    final relative =
        box.localToGlobal(Offset.zero).dy - viewportBox.localToGlobal(Offset.zero).dy;
    final viewportHeight = viewportBox.size.height;
    if (relative < viewportHeight * 0.25 || relative > viewportHeight * 0.7) {
      // First scroll after a chapter loads: jump silently so the lyrics
      // appear already-positioned. Otherwise we'd see the page spring
      // from offset 0 to ~40%-from-top in 320ms — looks like a bounce.
      if (_lastScrolledIndex < 0) {
        _scrollController
            .jumpTo(_scrollController.offset + (relative - viewportHeight * 0.4));
      } else {
        _scrollController
            .animateTo(
              _scrollController.offset + (relative - viewportHeight * 0.4),
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
            )
            .catchError((_) {});
      }
    }
    _lastScrolledIndex = index;
  }

  @override
  Widget build(BuildContext context) {
    final ctx = _audio.context;
    if (ctx == null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0),
        body: const Center(
          child: Text(
            'No audio loaded',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    final width = MediaQuery.of(context).size.width;
    final isWide = width > 820;
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
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
                color: Colors.grey.shade900,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      '${s.toStringAsFixed(s == s.roundToDouble() ? 1 : 2)}×',
                      style: const TextStyle(
                        color: Colors.white,
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
                            style: const TextStyle(color: Colors.white),
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
            ? _WideLayout(book: ctx.book, body: _buildLyricsView(), audio: _audio)
            : _NarrowLayout(book: ctx.book, body: _buildLyricsView(), audio: _audio),
      ),
    );
  }

  Widget _buildLyricsView() {
    return StreamBuilder<AudioWords>(
      stream: _audio.currentWords,
      initialData: _audio.currentWords.value,
      builder: (context, wordsSnap) {
        final words = wordsSnap.data ?? AudioWords.empty;
        _rebuildWordKeys(words);
        if (words.words.isEmpty) {
          // Fall back to the chapter's prose if no word timings —
          // playback still works, but without the karaoke effect.
          final ctx = _audio.context;
          final fallback = ctx == null
              ? ''
              : (ctx.chapters[ctx.currentChapterIndex].content);
          return SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
            child: Text(
              fallback.isEmpty
                  ? 'No lyrics available for this chapter.'
                  : fallback,
              style: const TextStyle(
                color: Colors.white54,
                fontSize: 20,
                height: 1.7,
              ),
            ),
          );
        }
        return StreamBuilder<int>(
          stream: _audio.currentWordIndex,
          initialData: _audio.currentWordIndex.value,
          builder: (context, idxSnap) {
            final activeIndex = idxSnap.data ?? -1;
            // Schedule a scroll-to-centre after layout so positions
            // are valid (the word's RenderBox must be attached).
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _maybeScrollTo(activeIndex);
            });
            return SingleChildScrollView(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 64),
              child: RichText(
                text: TextSpan(
                  children: [
                    for (var i = 0; i < words.words.length; i++)
                      WidgetSpan(
                        baseline: TextBaseline.alphabetic,
                        alignment: PlaceholderAlignment.baseline,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6, bottom: 4),
                          child: GestureDetector(
                            // Tap a word to seek to it — same gesture
                            // pattern as Apple Music's lyric view.
                            // The user's eye is already on the tapped
                            // word; suppress the auto-scroll the next
                            // tick would otherwise trigger.
                            onTap: () {
                              _suppressNextScroll = true;
                              _audio.seek(Duration(
                                milliseconds:
                                    (words.words[i].startSeconds * 1000)
                                        .round(),
                              ));
                            },
                            // Plain Text + DefaultTextStyle (no animation):
                            // a per-word 220ms cross-fade meant 1500 words
                            // simultaneously animating on a far seek, which
                            // looked like a full-screen flash. Single-frame
                            // recolor matches Apple Music's behaviour.
                            child: Text(
                              _displayWord(words.words[i].word),
                              key: _wordKeys[i],
                              style: TextStyle(
                                fontSize: 28,
                                height: 1.45,
                                fontWeight: i == activeIndex
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: i == activeIndex
                                    ? Colors.white
                                    : (i < activeIndex
                                        ? Colors.white.withOpacity(0.85)
                                        : Colors.white.withOpacity(0.32)),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Whisper produces "Chapter", "I,", "Down" — keep the punctuation
  /// glued to the preceding token so the rendered prose looks normal.
  String _displayWord(String w) => w;
}

/// Right-of-cover layout used on macOS / web / iPad-landscape.
class _WideLayout extends StatelessWidget {
  final FeedItemModel book;
  final Widget body;
  final AudioPlaybackService audio;
  const _WideLayout({required this.book, required this.body, required this.audio});

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
                _TitleStrip(book: book, audio: audio),
                const SizedBox(height: 8),
                _ScrubberControls(audio: audio),
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
  const _NarrowLayout({required this.book, required this.body, required this.audio});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(child: body),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
          child: _MiniNowPlaying(book: book, audio: audio),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: _ScrubberControls(audio: audio),
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
  const _MiniNowPlaying({required this.book, required this.audio});

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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${book.author} — ${book.title}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
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
  const _TitleStrip({required this.book, required this.audio});

  @override
  Widget build(BuildContext context) {
    final ctx = audio.context;
    final chapterTitle = ctx == null
        ? ''
        : (ctx.chapters[ctx.currentChapterIndex].title);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chapterTitle.isEmpty ? book.title : chapterTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${book.author} — ${book.title}',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 13,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// Scrubber + main transport controls. Encapsulated so both the wide
/// and narrow layouts use the exact same widget tree.
class _ScrubberControls extends StatelessWidget {
  final AudioPlaybackService audio;
  const _ScrubberControls({required this.audio});

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
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withOpacity(0.18),
                    thumbColor: Colors.white,
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
                          style: TextStyle(color: Colors.white.withOpacity(0.6))),
                      Text(
                        dur == Duration.zero
                            ? '--:--'
                            : '-${_fmt(dur - pos)}',
                        style: TextStyle(color: Colors.white.withOpacity(0.6)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.skip_previous, color: Colors.white, size: 28),
                      onPressed: audio.previousChapter,
                      tooltip: 'Previous chapter',
                    ),
                    IconButton(
                      icon: const Icon(Icons.replay_10, color: Colors.white, size: 28),
                      onPressed: () => audio.skipBackward(by: const Duration(seconds: 10)),
                      tooltip: 'Back 10s',
                    ),
                    StreamBuilder<PlayerState>(
                      stream: audio.playerStateStream,
                      builder: (context, snap) {
                        final state = snap.data;
                        final playing = state?.playing == true;
                        final loading = state?.processingState == ProcessingState.loading ||
                            state?.processingState == ProcessingState.buffering;
                        return IconButton(
                          iconSize: 56,
                          icon: loading
                              ? const SizedBox(
                                  width: 32,
                                  height: 32,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Icon(
                                  playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
                                  color: Colors.white,
                                  size: 56,
                                ),
                          onPressed: loading ? null : audio.togglePlayPause,
                        );
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.forward_30, color: Colors.white, size: 28),
                      onPressed: () => audio.skipForward(by: const Duration(seconds: 30)),
                      tooltip: 'Forward 30s',
                    ),
                    IconButton(
                      icon: const Icon(Icons.skip_next, color: Colors.white, size: 28),
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
