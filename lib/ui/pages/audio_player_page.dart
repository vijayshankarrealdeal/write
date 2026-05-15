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

  /// Centre the active word in the viewport when it changes by more
  /// than ~half a viewport, animate gently when it's a small jump.
  void _maybeScrollTo(int index) {
    if (index < 0 || index >= _wordKeys.length) return;
    if (index == _lastScrolledIndex) return;
    final key = _wordKeys[index];
    final ctx = key.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final position = box.localToGlobal(Offset.zero);
    // Find the closest enclosing Scrollable to keep the word centred
    // even when this widget is hosted inside a CustomScrollView (e.g.
    // tablet layout with a sliver app bar).
    final viewport = Scrollable.of(ctx);
    final viewportBox = viewport.context.findRenderObject() as RenderBox?;
    if (viewportBox == null) return;
    final viewportOffset = viewportBox.localToGlobal(Offset.zero);
    final relative = position.dy - viewportOffset.dy;
    final viewportHeight = viewportBox.size.height;
    if (relative < viewportHeight * 0.25 ||
        relative > viewportHeight * 0.7) {
      _scrollController
          .animateTo(
        _scrollController.offset + (relative - viewportHeight * 0.4),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      )
          .catchError((_) {});
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
                            onTap: () => _audio.seek(Duration(
                              milliseconds:
                                  (words.words[i].startSeconds * 1000).round(),
                            )),
                            child: AnimatedDefaultTextStyle(
                              key: _wordKeys[i],
                              duration: const Duration(milliseconds: 220),
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
                              child: Text(_displayWord(words.words[i].word)),
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

/// Stacked layout used on phones — cover at top, lyrics middle,
/// controls anchored at the bottom.
class _NarrowLayout extends StatelessWidget {
  final FeedItemModel book;
  final Widget body;
  final AudioPlaybackService audio;
  const _NarrowLayout({required this.book, required this.body, required this.audio});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
          child: AspectRatio(aspectRatio: 1, child: _CoverArt(book: book)),
        ),
        const SizedBox(height: 4),
        _TitleStrip(book: book, audio: audio),
        Expanded(child: body),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: _ScrubberControls(audio: audio),
        ),
      ],
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
                  child: Slider(
                    min: 0,
                    max: clampedMax,
                    value: clampedPos,
                    onChanged: (v) =>
                        audio.seek(Duration(milliseconds: v.round())),
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
