import 'dart:async';

import 'package:flutter/material.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/services/audio_playback_service.dart';
import 'package:inkspacex/ui/pages/audio_player_page.dart';

/// Pill-shaped "Listen" button shown in `PostDetailPage` for books
/// where at least one chapter has audio. Tapping it loads the book
/// into the audio service (resuming the saved position if any) and
/// opens the [AudioPlayerPage].
///
/// Hidden when no chapter has audio — keeps the reader UI clean for
/// text-only books.
class ListenButton extends StatelessWidget {
  final FeedItemModel book;
  /// Optional starting chapter. The author surfaces this when the
  /// user taps "Listen from here" inside a specific chapter; the
  /// home button leaves it null and we resume from the saved
  /// position.
  final String? startSectionId;

  const ListenButton({
    super.key,
    required this.book,
    this.startSectionId,
  });

  bool get _hasAnyAudio => book.sections.any((s) => s.hasAudio);

  @override
  Widget build(BuildContext context) {
    if (!_hasAnyAudio) return const SizedBox.shrink();
    return FilledButton.icon(
      icon: const Icon(Icons.headphones_rounded),
      label: const Text('Listen'),
      style: FilledButton.styleFrom(
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      ),
      onPressed: () async {
        final audio = AudioPlaybackService.instance;
        // Loading is fire-and-forget so the page transition feels
        // instant; just_audio will surface its own buffering state
        // through the player-state stream.
        unawaited(audio.loadBook(
          book,
          startSectionId: startSectionId,
          autoPlay: true,
        ));
        if (!context.mounted) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const AudioPlayerPage(),
            fullscreenDialog: true,
          ),
        );
      },
    );
  }
}

