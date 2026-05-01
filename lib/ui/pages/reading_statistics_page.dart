import 'dart:convert';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';

class ReadingStatisticsPage extends StatefulWidget {
  const ReadingStatisticsPage({super.key});

  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

enum _Range { week, month, year }

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  _Range _range = _Range.week;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureLoaded());
  }

  Future<void> _ensureLoaded() async {
    final userId = context.read<AuthProvider>().currentUser?.id;
    final feed = context.read<FeedProvider>();
    if (userId != null && feed.readingProgress.isEmpty) {
      await feed.loadReadingProgress(userId);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final pinkCardColor = isDark
        ? const Color(0xFF3A2735)
        : const Color(0xFFF3DCEB);
    final statCardColor = isDark
        ? const Color(0xFF1A1A1A)
        : const Color(0xFFF3F4F6);

    final feed = context.watch<FeedProvider>();
    final stats =
        _ReadingStats.from(feed.readingProgress, feed.items, _range);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          'Reading Statistics',
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: textColor),
        centerTitle: true,
      ),
      body: _loading && feed.readingProgress.isEmpty
          ? const Center(child: CupertinoActivityIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
                  children: [
                    _buildStreakCard(
                      stats.streakDays,
                      stats.longestStreak,
                      pinkCardColor,
                      isDark,
                    ),
                    const SizedBox(height: 24),
                    _buildRangeSelector(textColor),
                    const SizedBox(height: 24),
                    stats.hasAnyActivity
                        ? _buildChart(stats, textColor, isDark)
                        : _buildEmptyChart(textColor, isDark),
                    const SizedBox(height: 28),
                    _buildStatGrid(
                      stats: stats,
                      bg: statCardColor,
                      textColor: textColor,
                      isDark: isDark,
                    ),
                    if (_range == _Range.year) ...[
                      const SizedBox(height: 28),
                      _sectionHeader('Activity heatmap', textColor),
                      const SizedBox(height: 12),
                      _Heatmap(
                        dailyMinutes: stats.dailyMinutes,
                        isDark: isDark,
                      ),
                    ],
                    const SizedBox(height: 28),
                    _sectionHeader('Top reads', textColor),
                    const SizedBox(height: 12),
                    _buildTopReads(
                      stats: stats,
                      bg: statCardColor,
                      textColor: textColor,
                      isDark: isDark,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ─── Streak hero card ───
  Widget _buildStreakCard(
    int streakDays,
    int longestStreak,
    Color bg,
    bool isDark,
  ) {
    final accent = isDark ? Colors.white : const Color(0xFF2B1F3A);
    final label = streakDays == 1 ? '1 day streak' : '$streakDays days streak';
    final subtitle = streakDays == 0
        ? 'Start reading today to begin a streak!'
        : 'A little progress every day adds up.';
    final longestLabel = longestStreak == 0
        ? null
        : 'Longest: ${longestStreak == 1 ? '1 day' : '$longestStreak days'}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 26),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Icon(Icons.track_changes, size: 48, color: accent),
          const SizedBox(height: 12),
          Text(
            label,
            style: GoogleFonts.playfairDisplay(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13,
              color: accent.withValues(alpha: 0.75),
            ),
          ),
          if (longestLabel != null) ...[
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: isDark ? 0.10 : 0.07),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                longestLabel,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: accent.withValues(alpha: 0.85),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRangeSelector(Color textColor) {
    const activeColor = Color(0xFF6B7AF0);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: _Range.values.map((r) {
        final isActive = _range == r;
        final label = switch (r) {
          _Range.week => 'Week',
          _Range.month => 'Month',
          _Range.year => 'Year',
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: GestureDetector(
            onTap: () => setState(() => _range = r),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.transparent,
                borderRadius: BorderRadius.circular(30),
                border: Border.all(
                  color: isActive
                      ? activeColor
                      : textColor.withValues(alpha: 0.12),
                  width: isActive ? 1.6 : 1,
                ),
              ),
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: isActive
                      ? activeColor
                      : textColor.withValues(alpha: 0.7),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _sectionHeader(String label, Color textColor) {
    return Text(
      label,
      style: GoogleFonts.inter(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: textColor.withValues(alpha: 0.85),
        letterSpacing: -0.1,
      ),
    );
  }

  // ─── Chart ───
  Widget _buildEmptyChart(Color textColor, bool isDark) {
    return Container(
      height: 220,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.05)
              : Colors.black.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            CupertinoIcons.book,
            size: 28,
            color: textColor.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 10),
          Text(
            'No reading activity yet',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: textColor.withValues(alpha: 0.55),
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Open a book — your streak begins on the first day.',
            style: GoogleFonts.inter(
              fontSize: 12,
              color: textColor.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChart(_ReadingStats stats, Color textColor, bool isDark) {
    const activeColor = Color(0xFF6B7AF0);
    final trackColor = isDark
        ? Colors.white.withValues(alpha: 0.045)
        : Colors.black.withValues(alpha: 0.035);
    final inactiveColor = isDark
        ? const Color(0xFF2A2A3A)
        : const Color(0xFFE3E6F5);
    final gridColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);

    final bars = stats.bars;
    final peakIndex = stats.peakBarIndex;
    final maxMinutes = stats.maxBarMinutes;

    return SizedBox(
      height: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final maxH = constraints.maxHeight;
                return Stack(
                  children: [
                    // Subtle horizontal gridlines (4 levels).
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _GridPainter(color: gridColor),
                      ),
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(bars.length, (i) {
                        final bar = bars[i];
                        final isPeak = i == peakIndex && bar.minutes > 0;
                        final isFilled = bar.minutes > 0;
                        final heightFactor =
                            isFilled ? max(bar.value, 0.06) : 0.0;
                        return Expanded(
                          child: Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 5),
                            child: Stack(
                              alignment: Alignment.bottomCenter,
                              children: [
                                // Faint full-height track so empty days
                                // still read as "0", not as missing data.
                                Container(
                                  decoration: BoxDecoration(
                                    color: trackColor,
                                    borderRadius:
                                        BorderRadius.circular(12),
                                  ),
                                ),
                                if (isFilled)
                                  Container(
                                    height: maxH * heightFactor,
                                    decoration: BoxDecoration(
                                      color: isPeak
                                          ? activeColor
                                          : inactiveColor,
                                      borderRadius:
                                          BorderRadius.circular(12),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                    if (peakIndex >= 0 && bars[peakIndex].minutes > 0)
                      _buildPeakTooltip(
                        bars[peakIndex],
                        peakIndex,
                        bars.length,
                        textColor,
                        isDark,
                      ),
                    // Y-axis "max" label, top-left.
                    Positioned(
                      top: -2,
                      left: 0,
                      child: Text(
                        _formatMinutes(maxMinutes),
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: textColor.withValues(alpha: 0.4),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: bars
                .map(
                  (bar) => Expanded(
                    child: Center(
                      child: Text(
                        bar.label,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.6),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildPeakTooltip(
    _Bar bar,
    int index,
    int total,
    Color textColor,
    bool isDark,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final barWidth = constraints.maxWidth / total;
        final rawLeft = barWidth * index + barWidth / 2 - 48;
        final left = rawLeft.clamp(0, constraints.maxWidth - 96).toDouble();
        return Positioned(
          top: 0,
          left: left,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF22223A)
                  : const Color(0xFFEFF1FB),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bar.tooltipDate,
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: textColor.withValues(alpha: 0.5),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatMinutes(bar.minutes),
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ─── Stat grid (2 × 2) ───
  Widget _buildStatGrid({
    required _ReadingStats stats,
    required Color bg,
    required Color textColor,
    required bool isDark,
  }) {
    final rangeTotal = switch (_range) {
      _Range.week => 'Reading time this week',
      _Range.month => 'Reading time this month',
      _Range.year => 'Reading time this year',
    };
    final delta = stats.deltaPercent;
    final deltaLabel = delta == null
        ? null
        : (delta == 0
            ? 'Same as last ${_rangeNoun()}'
            : '${delta > 0 ? '+' : ''}$delta% vs last ${_rangeNoun()}');

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: rangeTotal,
                value: _formatMinutes(stats.totalMinutes),
                hint: deltaLabel,
                hintIsPositive:
                    delta != null && delta > 0 ? true : (delta == null ? null : false),
                bg: bg,
                textColor: textColor,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: 'Average session',
                value: _formatMinutes(stats.avgSessionMinutes),
                bg: bg,
                textColor: textColor,
                isDark: isDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _StatCard(
                label: 'Books completed',
                value: '${stats.booksCompleted}',
                bg: bg,
                textColor: textColor,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _StatCard(
                label: 'Best day',
                value: stats.bestDayMinutes > 0
                    ? _formatMinutes(stats.bestDayMinutes)
                    : '—',
                hint: stats.bestDayLabel,
                bg: bg,
                textColor: textColor,
                isDark: isDark,
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _rangeNoun() => switch (_range) {
        _Range.week => 'week',
        _Range.month => 'month',
        _Range.year => 'year',
      };

  // ─── Top reads ───
  Widget _buildTopReads({
    required _ReadingStats stats,
    required Color bg,
    required Color textColor,
    required bool isDark,
  }) {
    if (stats.topReads.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 22),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            'Read a few sections to see your favourites here',
            style: GoogleFonts.inter(
              fontSize: 12.5,
              color: textColor.withValues(alpha: 0.5),
            ),
          ),
        ),
      );
    }
    final maxMinutes = stats.topReads.first.minutes;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          for (var i = 0; i < stats.topReads.length; i++) ...[
            _TopReadRow(
              rank: i + 1,
              entry: stats.topReads[i],
              maxMinutes: maxMinutes,
              textColor: textColor,
              isDark: isDark,
            ),
            if (i < stats.topReads.length - 1)
              Divider(
                height: 1,
                color: textColor.withValues(alpha: 0.06),
                indent: 16,
                endIndent: 16,
              ),
          ],
        ],
      ),
    );
  }
}

// ===========================================================================
// Widgets
// ===========================================================================

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.bg,
    required this.textColor,
    required this.isDark,
    this.hint,
    this.hintIsPositive,
  });

  final String label;
  final String value;
  final Color bg;
  final Color textColor;
  final bool isDark;
  final String? hint;
  final bool? hintIsPositive;

  @override
  Widget build(BuildContext context) {
    final hintColor = hintIsPositive == null
        ? textColor.withValues(alpha: 0.45)
        : (hintIsPositive!
            ? const Color(0xFF34A853)
            : const Color(0xFFEA4335));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: textColor.withValues(alpha: 0.55),
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.playfairDisplay(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: GoogleFonts.inter(
                fontSize: 10.5,
                color: hintColor,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _TopReadRow extends StatelessWidget {
  const _TopReadRow({
    required this.rank,
    required this.entry,
    required this.maxMinutes,
    required this.textColor,
    required this.isDark,
  });

  final int rank;
  final _TopRead entry;
  final int maxMinutes;
  final Color textColor;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final fraction =
        maxMinutes == 0 ? 0.0 : entry.minutes / maxMinutes;
    final accent = isDark
        ? const Color(0xFF8FA0F5)
        : const Color(0xFF6B7AF0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '$rank',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: textColor.withValues(alpha: 0.4),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: textColor.withValues(alpha: 0.9),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (entry.author.isNotEmpty)
                  Text(
                    entry.author,
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: textColor.withValues(alpha: 0.45),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: fraction.clamp(0.0, 1.0),
                    backgroundColor: textColor.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation(accent),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _formatMinutes(entry.minutes),
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: textColor.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
    );
  }
}

// GitHub-style year heatmap. 7 rows (weekday) × ~53 cols.
class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.dailyMinutes, required this.isDark});

  final Map<DateTime, int> dailyMinutes;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          return CustomPaint(
            size: Size(constraints.maxWidth, 96),
            painter: _HeatmapPainter(
              dailyMinutes: dailyMinutes,
              isDark: isDark,
            ),
          );
        },
      ),
    );
  }
}

class _HeatmapPainter extends CustomPainter {
  _HeatmapPainter({required this.dailyMinutes, required this.isDark});

  final Map<DateTime, int> dailyMinutes;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day)
        .subtract(const Duration(days: 364));
    final emptyColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.05);

    // Find max for scaling.
    final values = dailyMinutes.values.toList();
    final maxV = values.isEmpty ? 0 : values.reduce(max);

    // 53 weekly columns × 7 rows.
    const rows = 7;
    const gap = 2.0;
    final cellSize = (size.height - gap * (rows - 1)) / rows;
    final cols = ((size.width + gap) / (cellSize + gap)).floor();
    final actualCols = min(cols, 53);

    // Align so "today" lands in the rightmost column.
    final offsetDays = (start.weekday - DateTime.monday) % 7;

    for (var c = 0; c < actualCols; c++) {
      for (var r = 0; r < rows; r++) {
        final dayIndex = c * 7 + r - offsetDays;
        if (dayIndex < 0 || dayIndex > 364) continue;
        final date = DateTime(start.year, start.month, start.day + dayIndex);
        final minutes = dailyMinutes[date] ?? 0;
        final color = minutes == 0
            ? emptyColor
            : _heatColor(minutes / max(maxV, 1));
        final rect = Rect.fromLTWH(
          c * (cellSize + gap),
          r * (cellSize + gap),
          cellSize,
          cellSize,
        );
        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(2));
        canvas.drawRRect(rrect, Paint()..color = color);
      }
    }
  }

  Color _heatColor(double t) {
    // Light → dark accent at higher intensities.
    const base = Color(0xFF6B7AF0);
    final clamped = t.clamp(0.0, 1.0);
    final alpha = 0.30 + 0.70 * clamped;
    return base.withValues(alpha: alpha);
  }

  @override
  bool shouldRepaint(_HeatmapPainter old) =>
      old.dailyMinutes != dailyMinutes || old.isDark != isDark;
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 1; i <= 3; i++) {
      final y = size.height * (i / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

// ===========================================================================
// Stats computation
// ===========================================================================

class _Bar {
  final String label;
  final int minutes;
  final String tooltipDate;
  final double value;
  const _Bar({
    required this.label,
    required this.minutes,
    required this.tooltipDate,
    required this.value,
  });
}

class _TopRead {
  final String title;
  final String author;
  final int minutes;
  const _TopRead(
      {required this.title, required this.author, required this.minutes});
}

class _ReadingStats {
  final List<_Bar> bars;
  final int streakDays;
  final int longestStreak;
  final int avgSessionMinutes;
  final int totalMinutes;
  final int peakBarIndex;
  final int maxBarMinutes;
  final bool hasAnyActivity;
  final int booksCompleted;
  final int bestDayMinutes;
  final String bestDayLabel;
  final List<_TopRead> topReads;
  final Map<DateTime, int> dailyMinutes;
  // Percentage delta vs the immediately preceding period of the same length.
  // Null if no prior data is available.
  final int? deltaPercent;

  const _ReadingStats({
    required this.bars,
    required this.streakDays,
    required this.longestStreak,
    required this.avgSessionMinutes,
    required this.totalMinutes,
    required this.peakBarIndex,
    required this.maxBarMinutes,
    required this.hasAnyActivity,
    required this.booksCompleted,
    required this.bestDayMinutes,
    required this.bestDayLabel,
    required this.topReads,
    required this.dailyMinutes,
    required this.deltaPercent,
  });

  factory _ReadingStats.from(
    List<ReadingProgressModel> progress,
    List<FeedItemModel> items,
    _Range range,
  ) {
    final minutesByItem = <String, int>{
      for (final item in items)
        item.id: _estimateReadingMinutes(item.sections),
    };
    final sectionCountById = <String, int>{
      for (final item in items) item.id: item.sections.length,
    };
    final itemById = <String, FeedItemModel>{
      for (final item in items) item.id: item,
    };

    int minutesFor(ReadingProgressModel p) {
      final total = minutesByItem[p.feedItemId] ?? 1;
      if (p.completed) return total;
      final sectionCount = sectionCountById[p.feedItemId] ?? 0;
      if (sectionCount <= 1) return total;
      final progressed =
          (p.scrollPosition + 1).clamp(1, sectionCount).toInt();
      return max(1, (total * progressed / sectionCount).round());
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    // Daily minutes for the full year (used by heatmap + best-day lookup).
    final dailyMinutes = <DateTime, int>{};
    for (final p in progress) {
      final day = DateTime(
        p.lastReadAt.year,
        p.lastReadAt.month,
        p.lastReadAt.day,
      );
      dailyMinutes[day] = (dailyMinutes[day] ?? 0) + minutesFor(p);
    }

    final List<_Bar> bars;
    final int totalMinutes;
    final int previousTotalMinutes;

    switch (range) {
      case _Range.week:
        final buckets = List<int>.filled(7, 0);
        final start = today.subtract(const Duration(days: 6));
        final prevStart = start.subtract(const Duration(days: 7));
        int prevTotal = 0;
        for (final p in progress) {
          final day = DateTime(
            p.lastReadAt.year,
            p.lastReadAt.month,
            p.lastReadAt.day,
          );
          final idx = day.difference(start).inDays;
          if (idx >= 0 && idx < 7) {
            buckets[idx] += minutesFor(p);
          } else {
            final prevIdx = day.difference(prevStart).inDays;
            if (prevIdx >= 0 && prevIdx < 7) {
              prevTotal += minutesFor(p);
            }
          }
        }
        const weekdayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
        final maxVal = buckets.fold<int>(0, max);
        bars = List.generate(7, (i) {
          final date = start.add(Duration(days: i));
          return _Bar(
            label: weekdayLabels[date.weekday - 1],
            minutes: buckets[i],
            tooltipDate: _formatShortDate(date),
            value: maxVal == 0 ? 0 : buckets[i] / maxVal,
          );
        });
        totalMinutes = buckets.fold<int>(0, (a, b) => a + b);
        previousTotalMinutes = prevTotal;
        break;

      case _Range.month:
        final buckets = List<int>.filled(4, 0);
        final start = today.subtract(const Duration(days: 27));
        final prevStart = start.subtract(const Duration(days: 28));
        int prevTotal = 0;
        for (final p in progress) {
          final day = DateTime(
            p.lastReadAt.year,
            p.lastReadAt.month,
            p.lastReadAt.day,
          );
          final dayDiff = day.difference(start).inDays;
          if (dayDiff >= 0 && dayDiff < 28) {
            buckets[dayDiff ~/ 7] += minutesFor(p);
          } else {
            final prevDiff = day.difference(prevStart).inDays;
            if (prevDiff >= 0 && prevDiff < 28) {
              prevTotal += minutesFor(p);
            }
          }
        }
        final maxVal = buckets.fold<int>(0, max);
        bars = List.generate(4, (i) {
          final weekStart = start.add(Duration(days: i * 7));
          final weekEnd = weekStart.add(const Duration(days: 6));
          return _Bar(
            label: 'W${i + 1}',
            minutes: buckets[i],
            tooltipDate:
                '${_formatShortDate(weekStart)} – ${_formatShortDate(weekEnd)}',
            value: maxVal == 0 ? 0 : buckets[i] / maxVal,
          );
        });
        totalMinutes = buckets.fold<int>(0, (a, b) => a + b);
        previousTotalMinutes = prevTotal;
        break;

      case _Range.year:
        final buckets = List<int>.filled(12, 0);
        int prevTotal = 0;
        for (final p in progress) {
          final diffMonths = (now.year - p.lastReadAt.year) * 12 +
              (now.month - p.lastReadAt.month);
          if (diffMonths >= 0 && diffMonths < 12) {
            buckets[11 - diffMonths] += minutesFor(p);
          } else if (diffMonths >= 12 && diffMonths < 24) {
            prevTotal += minutesFor(p);
          }
        }
        const monthLabels = [
          'J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D',
        ];
        final maxVal = buckets.fold<int>(0, max);
        bars = List.generate(12, (i) {
          final monthsAgo = 11 - i;
          final date = DateTime(now.year, now.month - monthsAgo, 1);
          return _Bar(
            label: monthLabels[date.month - 1],
            minutes: buckets[i],
            tooltipDate: _formatMonth(date),
            value: maxVal == 0 ? 0 : buckets[i] / maxVal,
          );
        });
        totalMinutes = buckets.fold<int>(0, (a, b) => a + b);
        previousTotalMinutes = prevTotal;
        break;
    }

    // Streak: consecutive days back from today with at least one read.
    final readDays = dailyMinutes.keys.toSet();
    int streak = 0;
    var cursor = today;
    if (!readDays.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    while (readDays.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    // Longest streak ever — scan all read days.
    final sortedDays = readDays.toList()..sort();
    int longest = 0;
    int run = 0;
    DateTime? prev;
    for (final d in sortedDays) {
      if (prev != null && d.difference(prev).inDays == 1) {
        run++;
      } else {
        run = 1;
      }
      if (run > longest) longest = run;
      prev = d;
    }

    // Average session: mean of estimated minutes across reading events
    // *in the current range*.
    final eventsInRange = progress.where((p) {
      final day = DateTime(
        p.lastReadAt.year,
        p.lastReadAt.month,
        p.lastReadAt.day,
      );
      switch (range) {
        case _Range.week:
          return !day.isBefore(today.subtract(const Duration(days: 6)));
        case _Range.month:
          return !day.isBefore(today.subtract(const Duration(days: 27)));
        case _Range.year:
          final diffMonths =
              (today.year - day.year) * 12 + (today.month - day.month);
          return diffMonths >= 0 && diffMonths < 12;
      }
    }).toList();

    final avgMinutes = eventsInRange.isEmpty
        ? 0
        : (eventsInRange.map(minutesFor).reduce((a, b) => a + b) /
                eventsInRange.length)
            .round();

    final booksCompleted = eventsInRange.where((p) => p.completed).length;

    // Best day — across the full range window.
    DateTime? bestDay;
    int bestVal = 0;
    final rangeStart = switch (range) {
      _Range.week => today.subtract(const Duration(days: 6)),
      _Range.month => today.subtract(const Duration(days: 27)),
      _Range.year => DateTime(today.year - 1, today.month, today.day + 1),
    };
    dailyMinutes.forEach((day, mins) {
      if (!day.isBefore(rangeStart) && mins > bestVal) {
        bestVal = mins;
        bestDay = day;
      }
    });
    final bestDayLabel = bestDay == null ? '' : _formatShortDate(bestDay!);

    // Top reads in range — by accumulated minutes per book.
    final readMinsByItem = <String, int>{};
    for (final p in eventsInRange) {
      readMinsByItem[p.feedItemId] =
          (readMinsByItem[p.feedItemId] ?? 0) + minutesFor(p);
    }
    final topEntries = readMinsByItem.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topReads = <_TopRead>[];
    for (final e in topEntries.take(5)) {
      final item = itemById[e.key];
      if (item == null) continue;
      topReads.add(_TopRead(
        title: item.title,
        author: item.author,
        minutes: e.value,
      ));
    }

    int peakIdx = -1;
    int peakVal = 0;
    for (var i = 0; i < bars.length; i++) {
      if (bars[i].minutes > peakVal) {
        peakVal = bars[i].minutes;
        peakIdx = i;
      }
    }

    int? delta;
    if (previousTotalMinutes > 0) {
      delta = (((totalMinutes - previousTotalMinutes) /
                  previousTotalMinutes) *
              100)
          .round();
    } else if (totalMinutes > 0) {
      delta = 100;
    }

    return _ReadingStats(
      bars: bars,
      streakDays: streak,
      longestStreak: longest,
      avgSessionMinutes: avgMinutes,
      totalMinutes: totalMinutes,
      peakBarIndex: peakIdx,
      maxBarMinutes: peakVal,
      hasAnyActivity: totalMinutes > 0,
      booksCompleted: booksCompleted,
      bestDayMinutes: bestVal,
      bestDayLabel: bestDayLabel,
      topReads: topReads,
      dailyMinutes: dailyMinutes,
      deltaPercent: delta,
    );
  }
}

// ===========================================================================
// Helpers
// ===========================================================================

int _estimateReadingMinutes(List<FeedItemSection> sections) {
  int totalWords = 0;
  for (final section in sections) {
    if (section.content.isEmpty) continue;
    try {
      final decoded = jsonDecode(section.content);
      if (decoded is List) {
        for (final op in decoded) {
          if (op is Map && op['insert'] is String) {
            totalWords +=
                (op['insert'] as String).split(RegExp(r'\s+')).length;
          }
        }
      }
    } catch (_) {}
  }
  return max(1, (totalWords / 238).ceil());
}

String _formatMinutes(int minutes) {
  if (minutes <= 0) return '0m';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _formatShortDate(DateTime d) =>
    '${d.day} ${_shortMonths[d.month - 1]} ${d.year}';

String _formatMonth(DateTime d) => '${_shortMonths[d.month - 1]} ${d.year}';
