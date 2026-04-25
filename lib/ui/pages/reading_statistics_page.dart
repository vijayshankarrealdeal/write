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
    final stats = _ReadingStats.from(feed.readingProgress, feed.items, _range);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          "Reading Statistics",
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
                constraints: const BoxConstraints(maxWidth: 520),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
                  children: [
                    _buildStreakCard(stats.streakDays, pinkCardColor, isDark),
                    const SizedBox(height: 24),
                    _buildRangeSelector(textColor),
                    const SizedBox(height: 28),
                    stats.hasAnyActivity
                        ? _buildChart(stats, textColor, isDark)
                        : _buildEmptyChart(textColor, isDark),
                    const SizedBox(height: 24),
                    Text(
                      "Your reading stats grow with every book you finish.\nSee your progress, stay inspired",
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: textColor.withValues(alpha: 0.6),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          child: _buildStatCard(
                            label: "average reading session",
                            value: _formatMinutes(stats.avgSessionMinutes),
                            bg: statCardColor,
                            textColor: textColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _buildStatCard(
                            label: _rangeTotalLabel(),
                            value: _formatMinutes(stats.totalMinutes),
                            bg: statCardColor,
                            textColor: textColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  String _rangeTotalLabel() => switch (_range) {
        _Range.week => "reading time this week",
        _Range.month => "reading time this month",
        _Range.year => "reading time this year",
      };

  Widget _buildStreakCard(int streakDays, Color bg, bool isDark) {
    final accent = isDark ? Colors.white : const Color(0xFF2B1F3A);
    final label = streakDays == 1 ? "1 day streak" : "$streakDays days streak";
    final subtitle = streakDays == 0
        ? "Start reading today to begin a streak!"
        : "A little progress every day adds up!";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        children: [
          Icon(Icons.track_changes, size: 52, color: accent),
          const SizedBox(height: 14),
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
          _Range.week => "Week",
          _Range.month => "Month",
          _Range.year => "Year",
        };
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: GestureDetector(
            onTap: () => setState(() => _range = r),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
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

  Widget _buildEmptyChart(Color textColor, bool isDark) {
    return Container(
      height: 220,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.black.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        "No reading activity yet",
        style: GoogleFonts.inter(
          fontSize: 14,
          color: textColor.withValues(alpha: 0.5),
        ),
      ),
    );
  }

  Widget _buildChart(_ReadingStats stats, Color textColor, bool isDark) {
    const activeColor = Color(0xFF6B7AF0);
    final inactiveColor = isDark
        ? const Color(0xFF2A2A3A)
        : const Color(0xFFE3E6F5);

    final bars = stats.bars;
    final peakIndex = stats.peakBarIndex;

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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: List.generate(bars.length, (i) {
                        final bar = bars[i];
                        final isPeak = i == peakIndex && bar.minutes > 0;
                        // Give tiny bars a minimum visible height if non-zero
                        final heightFactor = bar.value == 0
                            ? 0.0
                            : max(bar.value, 0.06);
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: Container(
                                height: maxH * heightFactor,
                                decoration: BoxDecoration(
                                  color: isPeak ? activeColor : inactiveColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
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
                          fontSize: 12,
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

  Widget _buildStatCard({
    required String label,
    required String value,
    required Color bg,
    required Color textColor,
  }) {
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
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: GoogleFonts.playfairDisplay(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Stats computation
// ---------------------------------------------------------------------------

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

class _ReadingStats {
  final List<_Bar> bars;
  final int streakDays;
  final int avgSessionMinutes;
  final int totalMinutes;
  final int peakBarIndex;
  final bool hasAnyActivity;

  const _ReadingStats({
    required this.bars,
    required this.streakDays,
    required this.avgSessionMinutes,
    required this.totalMinutes,
    required this.peakBarIndex,
    required this.hasAnyActivity,
  });

  factory _ReadingStats.from(
    List<ReadingProgressModel> progress,
    List<FeedItemModel> items,
    _Range range,
  ) {
    final minutesByItem = <String, int>{
      for (final item in items) item.id: _estimateReadingMinutes(item.sections),
    };
    final sectionCountById = <String, int>{
      for (final item in items) item.id: item.sections.length,
    };

    int minutesFor(ReadingProgressModel p) {
      final total = minutesByItem[p.feedItemId] ?? 1;
      if (p.completed) return total;
      final sectionCount = sectionCountById[p.feedItemId] ?? 0;
      if (sectionCount <= 1) return total;
      final progressed = (p.scrollPosition + 1).clamp(1, sectionCount).toInt();
      return max(1, (total * progressed / sectionCount).round());
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final List<_Bar> bars;
    final int totalMinutes;

    switch (range) {
      case _Range.week:
        final buckets = List<int>.filled(7, 0);
        final start = today.subtract(const Duration(days: 6));
        for (final p in progress) {
          final day = DateTime(
            p.lastReadAt.year,
            p.lastReadAt.month,
            p.lastReadAt.day,
          );
          final idx = day.difference(start).inDays;
          if (idx >= 0 && idx < 7) {
            buckets[idx] += minutesFor(p);
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
        break;

      case _Range.month:
        // 4 weekly buckets ending this week.
        final buckets = List<int>.filled(4, 0);
        final endOfWeek = today;
        final start = endOfWeek.subtract(const Duration(days: 27));
        for (final p in progress) {
          final day = DateTime(
            p.lastReadAt.year,
            p.lastReadAt.month,
            p.lastReadAt.day,
          );
          final dayDiff = day.difference(start).inDays;
          if (dayDiff >= 0 && dayDiff < 28) {
            buckets[dayDiff ~/ 7] += minutesFor(p);
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
        break;

      case _Range.year:
        final buckets = List<int>.filled(12, 0);
        // Rolling 12 months ending this month.
        for (final p in progress) {
          final diffMonths =
              (now.year - p.lastReadAt.year) * 12 +
                  (now.month - p.lastReadAt.month);
          if (diffMonths >= 0 && diffMonths < 12) {
            buckets[11 - diffMonths] += minutesFor(p);
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
        break;
    }

    // Streak: consecutive days back from today with at least one lastReadAt.
    final readDays = <DateTime>{
      for (final p in progress)
        DateTime(p.lastReadAt.year, p.lastReadAt.month, p.lastReadAt.day),
    };
    int streak = 0;
    var cursor = today;
    // If today hasn't been read yet but yesterday was, still count from yesterday.
    if (!readDays.contains(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    while (readDays.contains(cursor)) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }

    // Average session: mean of estimated minutes across reading events in range.
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
          final diffMonths = (today.year - day.year) * 12 +
              (today.month - day.month);
          return diffMonths >= 0 && diffMonths < 12;
      }
    }).toList();

    final avgMinutes = eventsInRange.isEmpty
        ? 0
        : (eventsInRange
                    .map((p) => minutesFor(p))
                    .reduce((a, b) => a + b) /
                eventsInRange.length)
            .round();

    int peakIdx = -1;
    int peakVal = 0;
    for (var i = 0; i < bars.length; i++) {
      if (bars[i].minutes > peakVal) {
        peakVal = bars[i].minutes;
        peakIdx = i;
      }
    }

    return _ReadingStats(
      bars: bars,
      streakDays: streak,
      avgSessionMinutes: avgMinutes,
      totalMinutes: totalMinutes,
      peakBarIndex: peakIdx,
      hasAnyActivity: totalMinutes > 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
