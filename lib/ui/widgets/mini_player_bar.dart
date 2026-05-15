import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'package:inkspacex/services/audio_playback_service.dart';
import 'package:inkspacex/ui/pages/audio_player_page.dart';

/// Persistent bottom strip that surfaces whatever the audio service
/// is currently playing — like the "now playing" sliver in Spotify
/// or Apple Music. Tapping anywhere on it pushes the full-screen
/// [AudioPlayerPage].
///
/// Renders nothing (a zero-height SizedBox) when there's no loaded
/// book, so the caller can park it above the bottom nav unconditionally.
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final audio = AudioPlaybackService.instance;
    return StreamBuilder<int?>(
      stream: audio.currentIndexStream,
      initialData: 0,
      builder: (context, _) {
        final ctx = audio.context;
        if (ctx == null || ctx.playable.isEmpty) {
          return const SizedBox.shrink();
        }
        final section = ctx.chapters[ctx.currentChapterIndex];
        final coverUrl = (ctx.book.coverImageUrl?.isNotEmpty == true
                ? ctx.book.coverImageUrl!
                : ctx.book.imageUrl)
            .trim();
        return Material(
          color: Theme.of(context).colorScheme.surface,
          elevation: 8,
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const AudioPlayerPage(),
                fullscreenDialog: true,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: coverUrl.isEmpty
                          ? Container(color: Colors.grey.shade400)
                          : CachedNetworkImage(
                              imageUrl: coverUrl,
                              fit: BoxFit.cover,
                              placeholder: (_, __) =>
                                  Container(color: Colors.grey.shade300),
                              errorWidget: (_, __, ___) =>
                                  Container(color: Colors.grey.shade400),
                            ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          section.title.isEmpty ? ctx.book.title : section.title,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          ctx.book.author,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurface
                                .withOpacity(0.65),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  StreamBuilder<PlayerState>(
                    stream: audio.playerStateStream,
                    builder: (context, snap) {
                      final playing = snap.data?.playing == true;
                      final loading = snap.data?.processingState ==
                              ProcessingState.loading ||
                          snap.data?.processingState ==
                              ProcessingState.buffering;
                      return IconButton(
                        icon: loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(playing ? Icons.pause : Icons.play_arrow),
                        onPressed: loading ? null : audio.togglePlayPause,
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.forward_30),
                    tooltip: 'Forward 30s',
                    onPressed: () =>
                        audio.skipForward(by: const Duration(seconds: 30)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
