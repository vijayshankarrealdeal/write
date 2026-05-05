import 'package:shared_preferences/shared_preferences.dart';

/// Persistent state for the editor's "daily word goal" feature.
///
/// Settings (target, widget enabled) live forever; today's progress is
/// keyed by date so it auto-resets when the date stored in prefs no
/// longer matches today.
class DailyGoalService {
  static const _kGoal = 'daily_goal_count_v1';
  static const _kEnabled = 'daily_goal_widget_enabled_v1';
  static const _kTodayDate = 'daily_goal_today_date_v1';
  static const _kTodayWords = 'daily_goal_today_words_v1';
  static const _kTodayMet = 'daily_goal_today_met_v1';

  static const int defaultGoal = 500;

  static String todayKey([DateTime? now]) {
    final n = now ?? DateTime.now();
    final y = n.year.toString().padLeft(4, '0');
    final m = n.month.toString().padLeft(2, '0');
    final d = n.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<DailyGoalState> load() async {
    final p = await SharedPreferences.getInstance();
    final goal = p.getInt(_kGoal) ?? defaultGoal;
    final enabled = p.getBool(_kEnabled) ?? false;
    final today = todayKey();
    final storedDate = p.getString(_kTodayDate);
    int words = 0;
    bool met = false;
    if (storedDate == today) {
      words = p.getInt(_kTodayWords) ?? 0;
      met = p.getBool(_kTodayMet) ?? false;
    } else {
      // Date rolled over — wipe yesterday's counters before returning.
      await p.setString(_kTodayDate, today);
      await p.setInt(_kTodayWords, 0);
      await p.setBool(_kTodayMet, false);
    }
    return DailyGoalState(
      goal: goal,
      enabled: enabled,
      todayDate: today,
      todayWords: words,
      todayMet: met,
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

  Future<void> setTodayWords(int words, {String? date}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTodayDate, date ?? todayKey());
    await p.setInt(_kTodayWords, words);
  }

  Future<void> setTodayMet(bool met, {String? date}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kTodayDate, date ?? todayKey());
    await p.setBool(_kTodayMet, met);
  }
}

class DailyGoalState {
  final int goal;
  final bool enabled;
  final String todayDate;
  final int todayWords;
  final bool todayMet;

  const DailyGoalState({
    required this.goal,
    required this.enabled,
    required this.todayDate,
    required this.todayWords,
    required this.todayMet,
  });
}
