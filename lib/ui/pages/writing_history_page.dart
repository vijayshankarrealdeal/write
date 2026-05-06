import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:inkspacex/services/daily_goal_service.dart';

/// Bar chart of words written per day. Reads `DailyGoalState.history`,
/// which the daily-goal service archives at midnight rollover.
class WritingHistoryPage extends StatefulWidget {
  const WritingHistoryPage({super.key});

  @override
  State<WritingHistoryPage> createState() => _WritingHistoryPageState();
}

enum _Range { week, twoWeeks, month }

class _WritingHistoryPageState extends State<WritingHistoryPage> {
  _Range _range = _Range.twoWeeks;
  final _service = DailyGoalService();
  Future<DailyGoalState>? _stateFuture;

  @override
  void initState() {
    super.initState();
    _stateFuture = _service.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = theme.textTheme.bodyMedium?.color ?? Colors.black;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Writing History',
          style: GoogleFonts.inter(fontWeight: FontWeight.w600),
        ),
      ),
      body: FutureBuilder<DailyGoalState>(
        future: _stateFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final state = snap.data!;
          final history = _seriesFor(state, _range);
          final maxWords = history
              .map((p) => p.words)
              .fold<int>(0, (a, b) => a > b ? a : b);
          final goal = state.goal;
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _summary(state, textColor),
                const SizedBox(height: 18),
                _segmentedRange(textColor, isDark),
                const SizedBox(height: 16),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.03)
                          : Colors.black.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _BarChart(
                      points: history,
                      maxWords:
                          maxWords > goal ? maxWords : (goal == 0 ? 1 : goal),
                      goal: goal,
                      textColor: textColor,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summary(DailyGoalState state, Color textColor) {
    return Wrap(
      spacing: 18,
      runSpacing: 8,
      children: [
        _stat('Today', '${state.todayWords}', textColor),
        _stat('Goal', '${state.goal}', textColor),
        _stat('Streak', '${state.streak} day${state.streak == 1 ? '' : 's'}',
            textColor),
        _stat(
          'Last 7 days',
          '${_sumLast(state.history, 7)} words',
          textColor,
        ),
      ],
    );
  }

  Widget _stat(String label, String value, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: GoogleFonts.inter(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: textColor.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
      ],
    );
  }

  int _sumLast(Map<String, int> history, int days) {
    final today = DateTime.now();
    var sum = 0;
    for (var i = 0; i < days; i++) {
      final d = today.subtract(Duration(days: i));
      sum += history[DailyGoalService.todayKey(d)] ?? 0;
    }
    return sum;
  }

  Widget _segmentedRange(Color textColor, bool isDark) {
    Widget chip(_Range r, String label) {
      final selected = r == _range;
      return GestureDetector(
        onTap: () => setState(() => _range = r),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? (isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: textColor.withValues(alpha: selected ? 1 : 0.65),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(_Range.week, 'Week'),
        const SizedBox(width: 6),
        chip(_Range.twoWeeks, '2 weeks'),
        const SizedBox(width: 6),
        chip(_Range.month, 'Month'),
      ],
    );
  }

  List<_HistoryPoint> _seriesFor(DailyGoalState state, _Range range) {
    final days = switch (range) {
      _Range.week => 7,
      _Range.twoWeeks => 14,
      _Range.month => 30,
    };
    final today = DateTime.now();
    final result = <_HistoryPoint>[];
    for (var i = days - 1; i >= 0; i--) {
      final d = today.subtract(Duration(days: i));
      final key = DailyGoalService.todayKey(d);
      final words = i == 0 ? state.todayWords : (state.history[key] ?? 0);
      result.add(_HistoryPoint(date: d, words: words));
    }
    return result;
  }
}

class _HistoryPoint {
  _HistoryPoint({required this.date, required this.words});
  final DateTime date;
  final int words;
}

class _BarChart extends StatelessWidget {
  const _BarChart({
    required this.points,
    required this.maxWords,
    required this.goal,
    required this.textColor,
  });

  final List<_HistoryPoint> points;
  final int maxWords;
  final int goal;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final barAreaHeight = c.maxHeight - 24;
      final goalY = goal == 0 ? null : barAreaHeight * (goal / maxWords);
      return Stack(
        children: [
          if (goalY != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 24 + (barAreaHeight - goalY).clamp(0, barAreaHeight),
              child: Row(
                children: [
                  Container(
                    height: 1,
                    width: 8,
                    color: Colors.greenAccent.withValues(alpha: 0.6),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'goal $goal',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      color: Colors.green.withValues(alpha: 0.85),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: 1,
                      decoration: BoxDecoration(
                        color: Colors.greenAccent.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final p in points)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.bottomCenter,
                              child: FractionallySizedBox(
                                heightFactor: maxWords == 0
                                    ? 0
                                    : (p.words / maxWords).clamp(0, 1).toDouble(),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: p.words >= goal && goal > 0
                                        ? Colors.greenAccent
                                            .withValues(alpha: 0.7)
                                        : Colors.blueAccent
                                            .withValues(alpha: 0.55),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(3),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _shortDayLabel(p.date),
                            style: GoogleFonts.inter(
                              fontSize: 9,
                              color: textColor.withValues(alpha: 0.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }

  String _shortDayLabel(DateTime d) {
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return labels[(d.weekday - 1) % 7];
  }
}
