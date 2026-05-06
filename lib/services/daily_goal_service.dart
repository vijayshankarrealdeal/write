import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Persistent state for the editor's "daily word goal" feature.
///
/// Holds three layers of state:
///   - **Settings**: target word count, widget visibility, reminder
///     hour/minute. These persist across days.
///   - **Today**: words written + whether the goal was met. Keyed by
///     the calendar date so reading on a new day silently resets.
///   - **Streak / history**: rolling 14-day word-count map and a
///     consecutive-days counter. Streak survives "missed yesterday"
///     only when the user explicitly opens the app — there's no
///     background reaper.
class DailyGoalService {
  // Settings
  static const _kGoal = 'daily_goal_count_v1';
  static const _kEnabled = 'daily_goal_widget_enabled_v1';
  static const _kReminderHour = 'daily_goal_reminder_hour_v1';
  static const _kReminderMinute = 'daily_goal_reminder_minute_v1';
  // Today
  static const _kTodayDate = 'daily_goal_today_date_v1';
  static const _kTodayWords = 'daily_goal_today_words_v1';
  static const _kTodayMet = 'daily_goal_today_met_v1';
  // Streak / history
  static const _kStreak = 'daily_goal_streak_v1';
  static const _kLastMetDate = 'daily_goal_last_met_date_v1';
  static const _kHistory = 'daily_goal_history_v1';

  static const int defaultGoal = 500;
  static const int defaultReminderHour = 21;
  static const int defaultReminderMinute = 0;
  static const int historyDays = 14;

  static String todayKey([DateTime? now]) {
    final n = now ?? DateTime.now();
    final y = n.year.toString().padLeft(4, '0');
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static String _yesterdayKey([DateTime? now]) {
    final n = (now ?? DateTime.now()).subtract(const Duration(days: 1));
    return todayKey(n);
  }

  Future<DailyGoalState> load() async {
    final p = await SharedPreferences.getInstance();
    final goal = p.getInt(_kGoal) ?? defaultGoal;
    final enabled = p.getBool(_kEnabled) ?? false;
    final hour = p.getInt(_kReminderHour) ?? defaultReminderHour;
    final minute = p.getInt(_kReminderMinute) ?? defaultReminderMinute;
    final today = todayKey();
    final storedDate = p.getString(_kTodayDate);
    int words = 0;
    bool met = false;
    if (storedDate == today) {
      words = p.getInt(_kTodayWords) ?? 0;
      met = p.getBool(_kTodayMet) ?? false;
    } else {
      // The previous "today" is now history — copy it into the rolling
      // map before wiping today's counters. This is the only point at
      // which the prior day gets archived; if the user skips a day
      // entirely it'll show up as a 0-word entry, which is correct.
      if (storedDate != null) {
        final priorWords = p.getInt(_kTodayWords) ?? 0;
        await _archiveDay(p, storedDate, priorWords);
      }
      await p.setString(_kTodayDate, today);
      await p.setInt(_kTodayWords, 0);
      await p.setBool(_kTodayMet, false);
    }
    // Streak: alive if last-met-date is today or yesterday; otherwise
    // it's broken. Reset eagerly so the UI doesn't show a stale "5
    // days" after the user missed a day.
    int streak = p.getInt(_kStreak) ?? 0;
    final lastMet = p.getString(_kLastMetDate);
    if (streak > 0 &&
        lastMet != today &&
        lastMet != _yesterdayKey()) {
      streak = 0;
      await p.setInt(_kStreak, 0);
    }
    final history = await _loadHistory(p);
    return DailyGoalState(
      goal: goal,
      enabled: enabled,
      reminderHour: hour,
      reminderMinute: minute,
      todayDate: today,
      todayWords: words,
      todayMet: met,
      streak: streak,
      lastMetDate: lastMet,
      history: history,
    );
  }

  Future<void> setGoal(int goal) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kGoal, goal);
  }

  Future<void> setEnabled(bool enabled) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, enabled);
  }

  Future<void> setReminderTime({required int hour, required int minute}) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kReminderHour, hour);
    await p.setInt(_kReminderMinute, minute);
  }

  Future<void> setTodayWords(int words, {String? date}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTodayDate, date ?? todayKey());
    await p.setInt(_kTodayWords, words);
  }

  /// Mark today met/unmet and update streak bookkeeping accordingly.
  /// Returns the new streak value.
  Future<int> setTodayMet(bool met, {String? date}) async {
    final p = await SharedPreferences.getInstance();
    final today = date ?? todayKey();
    await p.setString(_kTodayDate, today);
    await p.setBool(_kTodayMet, met);
    int streak = p.getInt(_kStreak) ?? 0;
    if (met) {
      final lastMet = p.getString(_kLastMetDate);
      if (lastMet == today) {
        // Already counted today's contribution to the streak.
      } else if (lastMet == _yesterdayKey()) {
        streak += 1;
      } else {
        // Either first ever met-day, or a gap — start a new streak.
        streak = 1;
      }
      await p.setInt(_kStreak, streak);
      await p.setString(_kLastMetDate, today);
    } else {
      // Un-met (e.g. user raised the goal so it's no longer satisfied):
      // only undo the streak increment if it was earned today.
      final lastMet = p.getString(_kLastMetDate);
      if (lastMet == today) {
        streak = (streak - 1).clamp(0, 1 << 30);
        await p.setInt(_kStreak, streak);
        // Roll last-met-date back to whatever the rolling history says.
        final hist = await _loadHistory(p);
        // The most recent met-day before today (best-effort).
        String? prior;
        for (final e in hist.entries) {
          if (e.key == today) continue;
          if ((e.value) > 0) {
            if (prior == null || e.key.compareTo(prior) > 0) prior = e.key;
          }
        }
        if (prior == null) {
          await p.remove(_kLastMetDate);
        } else {
          await p.setString(_kLastMetDate, prior);
        }
      }
    }
    return streak;
  }

  /// What today's word target should be when the writer has a manuscript
  /// goal + deadline set. Distributes the remaining work over the
  /// remaining days (inclusive of today). Returns null when the inputs
  /// don't justify a recommendation (no target / no deadline / deadline
  /// already passed / target already hit).
  static int? recommendedDailyGoal({
    required int? targetWordCount,
    required DateTime? targetDeadline,
    required int currentWordCount,
    DateTime? now,
  }) {
    if (targetWordCount == null || targetWordCount <= 0) return null;
    if (targetDeadline == null) return null;
    final today = DateTime(
      (now ?? DateTime.now()).year,
      (now ?? DateTime.now()).month,
      (now ?? DateTime.now()).day,
    );
    final deadlineDay = DateTime(
      targetDeadline.year,
      targetDeadline.month,
      targetDeadline.day,
    );
    final daysLeft = deadlineDay.difference(today).inDays + 1;
    if (daysLeft <= 0) return null;
    final remaining = targetWordCount - currentWordCount;
    if (remaining <= 0) return 0;
    final perDay = (remaining / daysLeft).ceil();
    return perDay < 50 ? 50 : perDay;
  }

  Future<Map<String, int>> _loadHistory(SharedPreferences p) async {
    final raw = p.getString(_kHistory);
    if (raw == null || raw.isEmpty) return <String, int>{};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return <String, int>{};
    }
  }

  Future<void> _archiveDay(
    SharedPreferences p,
    String date,
    int words,
  ) async {
    final history = await _loadHistory(p);
    history[date] = words;
    // Keep only the most recent N entries (lexical sort works because
    // keys are zero-padded yyyy-mm-dd).
    if (history.length > historyDays) {
      final sorted = history.entries.toList()
        ..sort((a, b) => b.key.compareTo(a.key));
      final trimmed = <String, int>{};
      for (final e in sorted.take(historyDays)) {
        trimmed[e.key] = e.value;
      }
      history
        ..clear()
        ..addAll(trimmed);
    }
    await p.setString(_kHistory, jsonEncode(history));
  }
}

class DailyGoalState {
  final int goal;
  final bool enabled;
  final int reminderHour;
  final int reminderMinute;
  final String todayDate;
  final int todayWords;
  final bool todayMet;
  final int streak;
  final String? lastMetDate;
  final Map<String, int> history;

  const DailyGoalState({
    required this.goal,
    required this.enabled,
    required this.reminderHour,
    required this.reminderMinute,
    required this.todayDate,
    required this.todayWords,
    required this.todayMet,
    required this.streak,
    required this.lastMetDate,
    required this.history,
  });
}
