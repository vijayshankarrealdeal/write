import 'package:inkspacex/services/daily_goal_service.dart';
import 'package:inkspacex/services/local_notification_service.dart';

/// Reads persisted goal state and pushes the right schedule into
/// [LocalNotificationService]. Idempotent — calling it again replaces
/// the prior schedule.
///
/// Call sites:
///   - app cold start in `main.dart`, so the reminder stays armed
///     even if the user never opens the editor today.
///   - editor settings changes (toggle, goal, reminder time, goal
///     met) which need an immediate reschedule.
///   - app resume across midnight, so the new day's schedule reflects
///     today's progress (which is zero on a fresh day).
class DailyGoalScheduler {
  DailyGoalScheduler({
    required this.notifications,
    DailyGoalService? service,
  }) : service = service ?? DailyGoalService();

  final LocalNotificationService notifications;
  final DailyGoalService service;

  Future<void> refresh() async {
    final s = await service.load();
    if (!s.enabled) {
      await notifications.cancelDailyGoalReminder();
      return;
    }
    final now = DateTime.now();
    var when = DateTime(
      now.year,
      now.month,
      now.day,
      s.reminderHour,
      s.reminderMinute,
    );
    final tomorrowOnly = s.todayMet || !when.isAfter(now);
    if (tomorrowOnly) {
      when = when.add(const Duration(days: 1));
    }
    final remaining = (s.goal - s.todayWords).clamp(0, s.goal);
    await notifications.scheduleDailyGoalReminder(
      when: when,
      wordsRemaining: remaining,
      dailyGoal: s.goal,
    );
  }
}
