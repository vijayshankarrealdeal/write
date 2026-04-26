import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/services/sync/merge_log.dart';

/// Hidden debug screen surfaced by long-pressing the version label in the
/// profile hub. Shows the most recent [MergeLog.maxEntries] merge decisions
/// the editor's `_mergeSections` has recorded — useful for understanding
/// when local edits get clobbered by stale remote payloads (or vice
/// versa) before deciding whether to upgrade to a real CRDT.
class MergeLogPage extends StatefulWidget {
  const MergeLogPage({super.key});

  @override
  State<MergeLogPage> createState() => _MergeLogPageState();
}

class _MergeLogPageState extends State<MergeLogPage> {
  late MergeLog _log;

  @override
  void initState() {
    super.initState();
    _log = context.read<MergeLog>();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final muted = textColor.withValues(alpha: 0.6);
    final entries = _log.snapshot().reversed.toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Merge log (${entries.length})',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            icon: const Icon(CupertinoIcons.delete),
            tooltip: 'Clear log',
            onPressed: () async {
              await _log.clear();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No merge decisions recorded yet.\n'
                  'This page logs every time the section-merge picks one '
                  'side\'s content over the other.',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(color: muted),
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              separatorBuilder: (_, __) => Divider(
                color: textColor.withValues(alpha: 0.08),
                height: 24,
              ),
              itemBuilder: (ctx, i) {
                final e = entries[i];
                final winnerColor = e.winner == 'local'
                    ? Colors.amber.withValues(alpha: 0.85)
                    : Colors.blue.withValues(alpha: 0.85);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: winnerColor.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'WINNER: ${e.winner.toUpperCase()}',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: winnerColor,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          e.observedAt.toLocal().toIso8601String(),
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10,
                            color: muted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'section ${e.sectionId}',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 12,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'local  ${e.localUpdatedAt.toIso8601String()}  '
                      '(${e.localLen} chars)',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: muted,
                      ),
                    ),
                    Text(
                      'remote ${e.remoteUpdatedAt.toIso8601String()}  '
                      '(${e.remoteLen} chars)',
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 11,
                        color: muted,
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}
