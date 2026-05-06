import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/carbon.dart';
import 'package:iconify_flutter/icons/ph.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:inkspacex/models/editor_annotation_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/provider/annotation_provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/settings_provider.dart';
import 'package:inkspacex/provider/spell_check_provider.dart';
import 'package:inkspacex/provider/version_history_provider.dart';
import 'package:inkspacex/services/daily_goal_service.dart';
import 'package:inkspacex/services/local_notification_service.dart';
import 'package:inkspacex/services/spell_check_decoration.dart';
import 'package:inkspacex/services/spell_check_service.dart' as spellsvc;
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/gemini_service.dart';
import 'package:inkspacex/web_utils_stub.dart'
    if (dart.library.html) 'package:inkspacex/web_utils.dart' as web_utils;
import 'package:inkspacex/ui/editor/command_palette.dart';
import 'package:inkspacex/ui/editor/floating_format_bar.dart';
import 'package:inkspacex/ui/editor/image_embed_builder.dart';
import 'package:inkspacex/ui/editor/slash_menu.dart';
import 'package:inkspacex/ui/editor/name_generator_dialog.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/canvas_page/canvas_editor.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/ai_bottom_sheet.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/annotations_panel.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/binder_pane.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/section_inspector.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/secondary_pane.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/views/cards_view.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/views/outline_view.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/views/view_switcher.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/comment_compose_dialog.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/editor_constants.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/find_replace_bar.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/focus_widgets.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/inline_spell_check_bar.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/ruler_bar.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/side_actions_pill.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/spell_check_sheet.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/toolbar_icon_button.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/toolbar_widgets.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/version_history_widgets.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/word_style_toolbar.dart';

/// Snapshot of the document scope an inline AI Assist panel is editing,
/// captured when the user picks an action from [AIActionPicker]. The panel
/// uses this to run the action and to splice the merged delta back into the
/// document on Apply — even if the user scrolls or interacts with chrome
/// while the panel is open.
class _AIPanelData {
  final AIAction action;
  final List<dynamic> sourceDelta;
  final String plainText;
  final bool hasSelection;
  final int replaceIndex;
  final int replaceLength;
  final bool sourceEndsWithNewline;
  const _AIPanelData({
    required this.action,
    required this.sourceDelta,
    required this.plainText,
    required this.hasSelection,
    required this.replaceIndex,
    required this.replaceLength,
    required this.sourceEndsWithNewline,
  });
}

class EditiorPage extends StatefulWidget {
  const EditiorPage({super.key});

  @override
  State<EditiorPage> createState() => _EditiorPageState();
}

class _EditiorPageState extends State<EditiorPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  bool _isReady = false;
  bool _imageUploading = false;
  bool _isCanvasMode = false;
  final _gemini = GeminiService();

  // ── Advanced Writer Features ──
  bool _focusMode = false;
  bool _typewriterMode = false;
  bool _showOutline = false;
  bool _showAnnotations = false;
  bool _showInspector = false;
  bool _showSplitView = false;
  // Width of the right-side reference pane. User-resizable by dragging
  // its left handle. Persisted only in-memory for now — survives across
  // toggles within a session, resets to default on app restart.
  double _splitViewWidth = 360;
  bool _findReplaceOpen = false;
  EditorViewMode _viewMode = EditorViewMode.draft;
  void Function()? _removeFindShortcutSuppressor;

  // ── AI Assist (on-canvas result panel) ──
  // Set after the user picks an action from the bottom-sheet [AIActionPicker].
  // While set, the editor card swaps QuillEditor for an AIAssistPanel that
  // renders the diff directly on the paper using editor typography.
  // Cleared by Apply / Decline / X / Try another.
  _AIPanelData? _aiPanel;

  // Tracks the section the AnnotationProvider is currently loaded for so we
  // only reload when the active section actually changes.
  String? _annotationSectionId;
  // Mirrors the same idea for the version-history provider, plus a Quill
  // listener handle so we can detach when the page disposes or the section
  // changes.
  String? _versionSectionId;
  VoidCallback? _docListener;
  QuillController? _listenerAttachedTo;
  String? _spellSectionId;
  PaperTheme _paperTheme = PaperTheme.defaultTheme;
  int _sessionStartWords = 0;
  bool _sessionStarted = false;
  int _dailyGoal = DailyGoalService.defaultGoal;
  bool _showGoalWidget = false;
  // Cross-session daily counter — persisted, keyed by date so it
  // auto-resets at midnight. Updated from positive deltas in the
  // active editor controller (so deletes never lower today's score).
  final DailyGoalService _goalService = DailyGoalService();
  int _dailyWordsToday = 0;
  bool _dailyMet = false;
  String _dailyDate = DailyGoalService.todayKey();
  int _streak = 0;
  int _reminderHour = DailyGoalService.defaultReminderHour;
  int _reminderMinute = DailyGoalService.defaultReminderMinute;
  Map<String, int> _dailyHistory = const <String, int>{};
  // Word-count tracking lives on a controller listener attached in
  // didChangeDependencies (re-attached whenever EditorProvider swaps
  // the controller — i.e. when the user opens a different section or
  // book). Going through a listener instead of computing deltas in
  // the goal-widget builder means we keep tracking even when the
  // floating widget is hidden, and never double-credit a section
  // swap as "freshly written" words.
  QuillController? _trackedGoalController;
  VoidCallback? _goalControllerListener;
  EditorProvider? _trackedEditorProvider;
  VoidCallback? _editorProviderListener;
  int _lastObservedWords = 0;
  Timer? _goalPersistTimer;
  Timer? _midnightTimer;
  String? _activePrompt;
  late AnimationController _focusModeController;
  late Animation<double> _focusModeAnimation;
  SlashMenuController? _slashMenu;

  // Editor surface: a long-lived ScrollController + FocusNode + EditorState
  // key let us drive typewriter-mode centering and selection theming
  // directly. They're owned by the page so QuillEditor.basic can rebuild
  // (e.g. on section switch via ValueKey) without losing scroll position
  // or focus across the swap.
  final ScrollController _editorScrollController = ScrollController();
  final FocusNode _editorFocusNode = FocusNode();
  final GlobalKey<EditorState> _editorStateKey = GlobalKey<EditorState>();
  // Listener attached to the QuillController while typewriter mode is on,
  // so detaching is a single removeListener call.
  VoidCallback? _typewriterListener;
  QuillController? _typewriterAttachedTo;
  // Coalesces back-to-back typewriter scrolls (every keystroke fires a
  // selection change) into one frame of work.
  bool _typewriterPending = false;

  // ── Page margins (functional ruler) ──
  // Live values; dragging the ruler triangles updates these and the page
  // card padding updates synchronously. Persisted in SharedPreferences so
  // the layout the user dialed in survives reload.
  static const double _defaultMargin = 48;
  double _leftMargin = _defaultMargin;
  double _rightMargin = _defaultMargin;
  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      'editor_opened',
      screen: '/editor',
      action: 'view',
    );
    WidgetsBinding.instance.addObserver(this);
    _focusModeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _focusModeAnimation = CurvedAnimation(
      parent: _focusModeController,
      curve: Curves.easeOutCubic,
    );
    for (final font in editorFonts) {
      try {
        GoogleFonts.getFont(font);
      } catch (_) {}
    }
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
    _removeFindShortcutSuppressor = web_utils.installFindShortcutSuppressor();
    _loadMargins();
    _loadDailyGoal();
  }

  // ── Daily goal: load + persist + notification scheduling ──

  Future<void> _loadDailyGoal() async {
    final s = await _goalService.load();
    if (!mounted) return;
    setState(() {
      _dailyGoal = s.goal;
      _showGoalWidget = s.enabled;
      _dailyWordsToday = s.todayWords;
      _dailyMet = s.todayMet;
      _dailyDate = s.todayDate;
      _streak = s.streak;
      _reminderHour = s.reminderHour;
      _reminderMinute = s.reminderMinute;
      _dailyHistory = s.history;
    });
    _refreshGoalReminder();
    _scheduleMidnightTick();
  }

  void _scheduleMidnightTick() {
    _midnightTimer?.cancel();
    final now = DateTime.now();
    // 00:00:05 of the next calendar day — a few seconds of slack so
    // the wall-clock has actually rolled over by the time we read it.
    final tomorrow = DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 1, seconds: 5));
    _midnightTimer = Timer(tomorrow.difference(now), () async {
      if (!mounted) return;
      _maybeRollDailyDate();
      await _refreshGoalReminder();
      _scheduleMidnightTick();
    });
  }

  /// Attach a listener to [c] so every doc-change emits a
  /// `_onWordCountTick` callback. Idempotent — if we're already on
  /// [c], this is a no-op. Detaches the prior controller's listener
  /// first to avoid leaks across section swaps.
  void _attachWordTracker(QuillController c) {
    if (identical(c, _trackedGoalController)) return;
    _detachWordTracker();
    _trackedGoalController = c;
    _lastObservedWords = _wordCountOf(c);
    _goalControllerListener = () {
      if (!mounted) return;
      _onWordCountTick(_wordCountOf(c));
    };
    c.addListener(_goalControllerListener!);
  }

  void _detachWordTracker() {
    final c = _trackedGoalController;
    final l = _goalControllerListener;
    if (c != null && l != null) {
      c.removeListener(l);
    }
    _trackedGoalController = null;
    _goalControllerListener = null;
  }

  int _wordCountOf(QuillController c) {
    final text = c.document.toPlainText().trim();
    if (text.isEmpty) return 0;
    return text.split(RegExp(r'\s+')).length;
  }

  void _applyGoalChange(int goal) {
    setState(() {
      _dailyGoal = goal;
      // Lowering the bar can flip today from "missed" to "met";
      // raising it can do the reverse. Recompute and let setTodayMet
      // reconcile the streak.
      _dailyMet = _dailyWordsToday >= _dailyGoal;
    });
    _goalService.setTodayMet(_dailyMet, date: _dailyDate).then((s) {
      if (!mounted) return;
      setState(() => _streak = s);
    });
    _persistGoalSetting();
  }

  /// Show a number-input dialog for a custom goal value. Returns the
  /// chosen value (rounded to a positive int) or null if cancelled.
  Future<int?> _promptCustomGoal() async {
    final controller = TextEditingController(text: '$_dailyGoal');
    final result = await showCupertinoDialog<int>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Custom daily goal'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            placeholder: 'Words per day',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              final v = int.tryParse(controller.text.trim());
              if (v == null || v <= 0) {
                Navigator.of(ctx).pop();
                return;
              }
              Navigator.of(ctx).pop(v);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    return result;
  }

  /// Cupertino time picker for the daily reminder. Returns hour/minute
  /// or null if cancelled.
  Future<TimeOfDay?> _pickReminderTime() async {
    var picked = TimeOfDay(hour: _reminderHour, minute: _reminderMinute);
    final ok = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (ctx) => Container(
        height: 280,
        color: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF111111)
            : Colors.white,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel'),
                  ),
                  CupertinoButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: const Text('Save'),
                  ),
                ],
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  use24hFormat: false,
                  initialDateTime: DateTime(
                    2020,
                    1,
                    1,
                    _reminderHour,
                    _reminderMinute,
                  ),
                  onDateTimeChanged: (dt) {
                    picked = TimeOfDay(hour: dt.hour, minute: dt.minute);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return null;
    return picked;
  }

  /// Sum of today's words plus the rolling 7-day history (excluding
  /// today, which lives in `_dailyWordsToday`). Used for a "this week"
  /// surface in the goal settings sheet.
  int _weekTotalWords() {
    var total = _dailyWordsToday;
    final cutoff = DateTime.now().subtract(const Duration(days: 6));
    final cutoffKey = DailyGoalService.todayKey(cutoff);
    for (final e in _dailyHistory.entries) {
      if (e.key.compareTo(cutoffKey) >= 0 && e.key != _dailyDate) {
        total += e.value;
      }
    }
    return total;
  }

  String _formatReminderTime() {
    final h12 = _reminderHour == 0
        ? 12
        : (_reminderHour > 12 ? _reminderHour - 12 : _reminderHour);
    final mm = _reminderMinute.toString().padLeft(2, '0');
    final suffix = _reminderHour >= 12 ? 'PM' : 'AM';
    return '$h12:$mm $suffix';
  }

  Future<void> _persistGoalSetting({bool promptForPermission = false}) async {
    await _goalService.setGoal(_dailyGoal);
    await _goalService.setEnabled(_showGoalWidget);
    if (promptForPermission && _showGoalWidget) {
      await _ensureNotificationPermissionForGoal();
    }
    _refreshGoalReminder();
  }

  /// Re-checks (and re-requests if needed) OS notification permission
  /// when the user opts into the daily goal reminder. If the OS still
  /// won't deliver, surface a snackbar pointing to system Settings —
  /// otherwise the schedule call is a silent no-op and the user
  /// wonders why nothing ever fires.
  Future<void> _ensureNotificationPermissionForGoal() async {
    if (!mounted) return;
    final notifs = context.read<LocalNotificationService>();
    final enabled = await notifs.areNotificationsEnabled();
    if (enabled) return;
    final granted = await notifs.requestNotificationPermission();
    if (granted || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'Notifications are off — enable them in Settings to get '
          'daily writing reminders.',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _persistDailyTotalDebounced() {
    _goalPersistTimer?.cancel();
    _goalPersistTimer = Timer(const Duration(seconds: 2), () {
      _goalService.setTodayWords(_dailyWordsToday, date: _dailyDate);
    });
  }

  void _maybeRollDailyDate() {
    final today = DailyGoalService.todayKey();
    if (today == _dailyDate) return;
    setState(() {
      _dailyDate = today;
      _dailyWordsToday = 0;
      _dailyMet = false;
    });
    // Wipe yesterday's counters so reload-from-prefs sees a fresh day.
    _goalService.setTodayWords(0, date: today);
    _goalService.setTodayMet(false, date: today);
  }

  void _onWordCountTick(int currentWords) {
    if (!mounted) return;
    _maybeRollDailyDate();
    final delta = currentWords - _lastObservedWords;
    _lastObservedWords = currentWords;
    if (delta <= 0) return;
    setState(() {
      _dailyWordsToday += delta;
    });
    _persistDailyTotalDebounced();
    if (!_dailyMet && _dailyWordsToday >= _dailyGoal) {
      _dailyMet = true;
      // setTodayMet returns the post-update streak so we can mirror it
      // into UI state without a second prefs read.
      _goalService.setTodayMet(true, date: _dailyDate).then((newStreak) {
        if (!mounted) return;
        setState(() => _streak = newStreak);
      });
      // Goal hit → no need to nag the user this evening. Reschedule
      // for tomorrow so the streak prompt resumes on a new day.
      _refreshGoalReminder();
    }
  }

  /// Recompute the next reminder time from current state and push it
  /// to [LocalNotificationService]. Called whenever something that
  /// affects scheduling changes: settings load, toggle, goal value,
  /// goal-met crossover.
  Future<void> _refreshGoalReminder() async {
    if (!mounted) return;
    final notifs = context.read<LocalNotificationService>();
    if (!_showGoalWidget) {
      await notifs.cancelDailyGoalReminder();
      return;
    }
    final now = DateTime.now();
    var when = DateTime(
      now.year,
      now.month,
      now.day,
      _reminderHour,
      _reminderMinute,
    );
    final tomorrowOnly = _dailyMet || !when.isAfter(now);
    if (tomorrowOnly) {
      when = when.add(const Duration(days: 1));
    }
    final remaining = (_dailyGoal - _dailyWordsToday).clamp(0, _dailyGoal);
    await notifs.scheduleDailyGoalReminder(
      when: when,
      wordsRemaining: remaining,
      dailyGoal: _dailyGoal,
    );
  }

  // ── Margin persistence ──
  static const _kLeftMarginKey = 'editor_left_margin_v1';
  static const _kRightMarginKey = 'editor_right_margin_v1';

  Future<void> _loadMargins() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _leftMargin = prefs.getDouble(_kLeftMarginKey) ?? _defaultMargin;
      _rightMargin = prefs.getDouble(_kRightMarginKey) ?? _defaultMargin;
    });
  }

  void _setMargins(double left, double right) {
    setState(() {
      _leftMargin = left;
      _rightMargin = right;
    });
    SharedPreferences.getInstance().then((p) {
      p.setDouble(_kLeftMarginKey, left);
      p.setDouble(_kRightMarginKey, right);
    });
  }

  // Global key handler — runs even while the Quill editor has focus, where
  // a wrapping KeyboardListener with an unfocused FocusNode silently never
  // fires. Returning `true` marks the event handled so it stops bubbling.
  bool _handleGlobalKey(KeyEvent event) {
    if (!mounted) return false;
    // Don't steal keys if a dialog or sheet is on top.
    if (ModalRoute.of(context)?.isCurrent != true) return false;

    // Slash menu eats arrows / Enter / Esc when open.
    if (_slashMenu?.handleKey(event) ?? false) return true;
    if (event is! KeyDownEvent) return false;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_aiPanel != null) {
        _closeAIPanel();
        return true;
      }
      if (_findReplaceOpen) {
        setState(() => _findReplaceOpen = false);
        return true;
      }
      if (_activePrompt != null) {
        setState(() => _activePrompt = null);
        return true;
      }
      if (_focusMode) {
        _toggleFocusMode();
        return true;
      }
      return false;
    }

    final ctrlOrCmd = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!ctrlOrCmd) return false;

    // On web, defer Cmd+F to the browser's native Find-in-Page so users don't
    // see two find bars stacked. The toolbar button and command palette still
    // open our custom bar for replace.
    if (event.logicalKey == LogicalKeyboardKey.keyF &&
        !_isCanvasMode &&
        !kIsWeb) {
      setState(() => _findReplaceOpen = !_findReplaceOpen);
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyK) {
      _openCommandPalette();
      return true;
    }
    return false;
  }

  // Wraps a modal sheet/dialog body so Escape pops the route on desktop/web.
  // Focus(autofocus) is required when the sheet has no text input — without
  // it CallbackShortcuts has no focused descendant and never fires.
  Widget _escapeDismiss(BuildContext sheetCtx, Widget child) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(sheetCtx).pop(),
      },
      child: Focus(autofocus: true, child: child),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      route.animation?.addStatusListener(_routeAnimationListener);
    }
    // Re-bind goal-tracking to the EditorProvider exposed by the
    // current scope. didChangeDependencies fires whenever providers
    // up the tree change, so this also re-attaches if the user logs
    // out/in (which rebuilds EditorProvider) without unmounting.
    final ep = context.read<EditorProvider>();
    if (ep != _trackedEditorProvider) {
      if (_trackedEditorProvider != null && _editorProviderListener != null) {
        _trackedEditorProvider!.removeListener(_editorProviderListener!);
      }
      _trackedEditorProvider = ep;
      _editorProviderListener = () {
        if (!mounted) return;
        _attachWordTracker(ep.controller);
      };
      ep.addListener(_editorProviderListener!);
      // Attach immediately for the initial controller — subsequent
      // swaps come through the listener above.
      _attachWordTracker(ep.controller);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      context.read<EditorProvider>().forceSaveImmediately();
      // Capture a snapshot for the version history too — the user may
      // not return, and an idle-timer snapshot won't fire if the app is
      // suspended before the timer expires.
      final controller = context.read<EditorProvider>().controller;
      context.read<VersionHistoryProvider>().flush(controller);
      // Flush today's word counter — pause may be the last thing that
      // happens before the OS kills the process.
      if (_goalPersistTimer?.isActive ?? false) {
        _goalPersistTimer!.cancel();
        _goalService.setTodayWords(_dailyWordsToday, date: _dailyDate);
      }
    } else if (state == AppLifecycleState.resumed) {
      // App may have been backgrounded across midnight. If the date
      // rolled over, reset today's counter and re-arm the reminder.
      _maybeRollDailyDate();
      _refreshGoalReminder();
      // Re-poll permission: user may have toggled notifications on
      // (or off) in system Settings while the app was backgrounded.
      // No prompt — we silently re-evaluate so the schedule call in
      // _refreshGoalReminder is a no-op or a real schedule per the
      // current state, and the next toggle-on shows the snackbar
      // again if appropriate.
      _maybeRescheduleMidnightTimer();
    }
  }

  void _maybeRescheduleMidnightTimer() {
    final fires = _midnightTimer?.isActive ?? false;
    if (!fires) _scheduleMidnightTick();
  }

  void _routeAnimationListener(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      ModalRoute.of(context)
          ?.animation
          ?.removeStatusListener(_routeAnimationListener);
      context.read<EditorProvider>().initEditor();
      if (mounted) {
        setState(() => _isReady = true);
        _initSessionTracking();
        _initSlashMenu();
      }
    }
  }

  void _initSlashMenu() {
    _slashMenu?.dispose();
    _slashMenu = SlashMenuController(
      controller: context.read<EditorProvider>().controller,
      context: context,
      onAction: _applySlashAction,
    );
  }

  // ─── Annotations ───
  // Yellow background tint applied to the anchored range as a visual marker.
  // Quill's background attribute travels with the text through edits, so the
  // marker stays in sync without us shifting offsets.
  static const String _annotationHighlightHex = '#FFE066';

  /// Reload annotations whenever the active section changes. Called from
  /// the build method so it stays in sync with provider changes.
  void _syncAnnotationSection(SectionModel? section) {
    if (section == null) {
      if (_annotationSectionId != null) {
        _annotationSectionId = null;
        context.read<AnnotationProvider>().clear();
      }
      return;
    }
    if (_annotationSectionId == section.id) return;
    _annotationSectionId = section.id;
    final controller = context.read<EditorProvider>().controller;
    final plain = controller.document.toPlainText();
    context.read<AnnotationProvider>().loadForSection(section.id, plain);
  }

  Future<void> _addAnnotationFromSelection() async {
    final auth = context.read<AuthProvider>();
    final editor = context.read<EditorProvider>();
    final section = editor.activeSection;
    if (section == null) return;
    final controller = editor.controller;
    final selection = controller.selection;
    if (!selection.isValid || selection.isCollapsed) return;
    final start = math.min(selection.baseOffset, selection.extentOffset);
    final end = math.max(selection.baseOffset, selection.extentOffset);
    final length = end - start;
    if (length <= 0) return;
    final anchored = controller.document.getPlainText(start, length);

    final body = await showDialog<String>(
      context: context,
      builder: (ctx) => CommentComposeDialog(
        anchoredText: anchored,
        isDark: Theme.of(ctx).brightness == Brightness.dark,
      ),
    );
    if (body == null || body.trim().isEmpty || !mounted) return;

    // Make sure the provider is loaded for this section before adding.
    final ann = context.read<AnnotationProvider>();
    if (ann.sectionId != section.id) {
      ann.loadForSection(section.id, controller.document.toPlainText());
    }
    final user = auth.currentUser;
    await ann.add(
      authorId: user?.id ?? 'local',
      authorName: user?.name ?? 'You',
      body: body.trim(),
      anchorStart: start,
      anchorLength: length,
      anchoredText: anchored,
    );

    // Paint the marker. BackgroundAttribute moves with the text on edits.
    controller.formatText(
      start,
      length,
      const BackgroundAttribute(_annotationHighlightHex),
    );

    if (mounted && !_showAnnotations) {
      setState(() => _showAnnotations = true);
    }
  }

  void _jumpToAnnotation(EditorAnnotation a) {
    final controller = context.read<EditorProvider>().controller;
    final text = controller.document.toPlainText();
    int start = a.anchorStart;
    int length = a.anchorLength;
    final inBounds = start >= 0 && start + length <= text.length;
    final stillMatches = inBounds &&
        text.substring(start, start + length) == a.anchoredText;
    if (!stillMatches && a.anchoredText.isNotEmpty) {
      final found = text.indexOf(a.anchoredText);
      if (found >= 0) {
        start = found;
        length = a.anchoredText.length;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Original text was removed from the document.')),
        );
        return;
      }
    }
    controller.updateSelection(
      TextSelection(baseOffset: start, extentOffset: start + length),
      ChangeSource.local,
    );
  }

  // ─── Version history ───
  // Auto-snapshots ride on the document's `changes` listener: every keystroke
  // resets a 30s idle timer in the provider; the snapshot fires once typing
  // stops. Section switches load that section's history; app pause flushes.

  void _syncVersionSection(SectionModel? section) {
    final vh = context.read<VersionHistoryProvider>();
    final controller = context.read<EditorProvider>().controller;
    if (section == null) {
      _detachDocListener();
      if (_versionSectionId != null) {
        _versionSectionId = null;
        vh.clear();
      }
      return;
    }
    if (_versionSectionId == section.id &&
        _listenerAttachedTo == controller) {
      return;
    }
    _versionSectionId = section.id;
    vh.loadForSection(section.id);
    _attachDocListener(controller, vh);
  }

  void _attachDocListener(QuillController controller, VersionHistoryProvider vh) {
    if (_listenerAttachedTo == controller && _docListener != null) return;
    _detachDocListener();
    void listener() {
      vh.scheduleSnapshot(controller);
    }
    controller.addListener(listener);
    _docListener = listener;
    _listenerAttachedTo = controller;
  }

  void _detachDocListener() {
    final l = _docListener;
    final c = _listenerAttachedTo;
    if (l != null && c != null) {
      c.removeListener(l);
    }
    _docListener = null;
    _listenerAttachedTo = null;
  }

  // ─── Spell check ───
  // Provider holds the current section's misspellings; the editor wires
  // it to the active QuillController on each section change. Status bar
  // surfaces the count and opens a sheet for navigation + replace.
  void _syncSpellSection(SectionModel? section) {
    final sp = context.read<SpellCheckProvider>();
    if (section == null) {
      if (_spellSectionId != null) {
        _spellSectionId = null;
        sp.detach();
      }
      return;
    }
    if (_spellSectionId == section.id) return;
    _spellSectionId = section.id;
    sp.attach(context.read<EditorProvider>().controller);
  }

  void _replaceMisspelling(spellsvc.Misspelling m, String replacement) {
    final controller = context.read<EditorProvider>().controller;
    final text = controller.document.toPlainText();
    int start = m.start;
    int length = m.length;
    final inBounds = start >= 0 && start + length <= text.length;
    final stillMatches = inBounds &&
        text.substring(start, start + length).toLowerCase() ==
            text.substring(start, start + length).toLowerCase() &&
        text.substring(start, start + length).toLowerCase().contains(
            m.word.toLowerCase());
    if (!stillMatches) {
      // Re-find by word — closest occurrence to original offset.
      final lower = text.toLowerCase();
      final candidate = lower.indexOf(m.word.toLowerCase());
      if (candidate < 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('That misspelling is no longer in the document.')),
        );
        return;
      }
      start = candidate;
      length = m.word.length;
    }
    controller.replaceText(
      start,
      length,
      replacement,
      TextSelection.collapsed(offset: start + replacement.length),
    );
  }

  void _showSpellCheckSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetCtx, scroll) => _escapeDismiss(
          sheetCtx,
          SpellCheckSheet(
            scrollController: scroll,
            isDark: Theme.of(context).brightness == Brightness.dark,
            onJump: (m) {
              final controller = context.read<EditorProvider>().controller;
              controller.updateSelection(
                TextSelection(
                    baseOffset: m.start, extentOffset: m.start + m.length),
                ChangeSource.local,
              );
            },
            onReplace: _replaceMisspelling,
            onAddToDictionary: (m) =>
                context.read<SpellCheckProvider>().addToDictionary(m.word),
            onIgnore: (m) =>
                context.read<SpellCheckProvider>().dismissIssue(m),
          ),
        ),
      ),
    );
  }

  Future<void> _saveManualVersion() async {
    final controller = context.read<EditorProvider>().controller;
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => VersionLabelDialog(
        isDark: Theme.of(ctx).brightness == Brightness.dark,
      ),
    );
    if (label == null || !mounted) return;
    final v = await context
        .read<VersionHistoryProvider>()
        .captureManual(controller, label: label);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(v == null
            ? 'No changes since last version.'
            : 'Saved version "${label.isEmpty ? 'untitled' : label}".'),
      ),
    );
  }

  void _showVersionHistory() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (sheetCtx, scroll) => VersionHistorySheet(
          scrollController: scroll,
          isDark: Theme.of(context).brightness == Brightness.dark,
          onSaveCurrent: () async {
            Navigator.pop(sheetCtx);
            await _saveManualVersion();
          },
          onRestore: (v) async {
            final ok = await Navigator.of(sheetCtx).push<bool>(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => VersionPreviewPage(
                  version: v,
                  isDark: Theme.of(context).brightness == Brightness.dark,
                ),
              ),
            );
            if (ok != true || !mounted) return;
            final controller = context.read<EditorProvider>().controller;
            await context.read<VersionHistoryProvider>().restore(v, controller);
            if (!mounted) return;
            if (sheetCtx.mounted) Navigator.pop(sheetCtx);
          },
        ),
      ),
    );
  }

  Future<void> _deleteAnnotation(EditorAnnotation a) async {
    final controller = context.read<EditorProvider>().controller;
    final text = controller.document.toPlainText();
    int start = a.anchorStart;
    int length = a.anchorLength;
    final inBounds = start >= 0 && start + length <= text.length;
    final stillMatches = inBounds &&
        text.substring(start, start + length) == a.anchoredText;
    if (!stillMatches && a.anchoredText.isNotEmpty) {
      final found = text.indexOf(a.anchoredText);
      if (found >= 0) {
        start = found;
        length = a.anchoredText.length;
      } else {
        // Anchor lost — just drop the data record; nothing to repaint.
        await context.read<AnnotationProvider>().remove(a.id);
        return;
      }
    }
    // Strip the highlight tint we added on creation.
    controller.formatText(
      start,
      length,
      const BackgroundAttribute(null),
    );
    await context.read<AnnotationProvider>().remove(a.id);
  }

  void _initSessionTracking() {
    if (_sessionStarted) return;
    final provider = context.read<EditorProvider>();
    final text = provider.controller.document.toPlainText().trim();
    _sessionStartWords = text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
    _sessionStarted = true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _removeFindShortcutSuppressor?.call();
    WidgetsBinding.instance.removeObserver(this);
    _focusModeController.dispose();
    _slashMenu?.dispose();
    _detachDocListener();
    _detachTypewriterListener();
    // Flush a pending word-count persist before tearing down so we
    // don't lose the last few seconds of writing on close.
    if (_goalPersistTimer?.isActive ?? false) {
      _goalPersistTimer!.cancel();
      _goalService.setTodayWords(_dailyWordsToday, date: _dailyDate);
    }
    _midnightTimer?.cancel();
    _detachWordTracker();
    if (_trackedEditorProvider != null && _editorProviderListener != null) {
      _trackedEditorProvider!.removeListener(_editorProviderListener!);
      _trackedEditorProvider = null;
      _editorProviderListener = null;
    }
    _editorScrollController.dispose();
    _editorFocusNode.dispose();
    super.dispose();
  }

  // ─── Typewriter mode ───
  // Listens for selection changes on the active QuillController and
  // animates the editor scroll so the caret stays in the upper-middle
  // band of the viewport — the "always typing on the same line" feel
  // that makes long-form drafting addictive.
  void _attachTypewriterListenerIfNeeded(QuillController controller) {
    if (!_typewriterMode) {
      _detachTypewriterListener();
      return;
    }
    if (_typewriterAttachedTo == controller && _typewriterListener != null) {
      return;
    }
    _detachTypewriterListener();
    void listener() => _scheduleTypewriterRecenter();
    controller.addListener(listener);
    _typewriterListener = listener;
    _typewriterAttachedTo = controller;
  }

  void _detachTypewriterListener() {
    final l = _typewriterListener;
    final c = _typewriterAttachedTo;
    if (l != null && c != null) {
      c.removeListener(l);
    }
    _typewriterListener = null;
    _typewriterAttachedTo = null;
  }

  void _scheduleTypewriterRecenter() {
    if (_typewriterPending) return;
    _typewriterPending = true;
    // One post-frame is enough — the EditorState has laid out the new
    // caret position by the time selection-change listeners fire on the
    // next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _typewriterPending = false;
      _recenterCaret();
    });
  }

  void _recenterCaret() {
    if (!mounted || !_typewriterMode) return;
    final scroll = _editorScrollController;
    if (!scroll.hasClients) return;
    final editorState = _editorStateKey.currentState;
    if (editorState == null) return;
    final controller = context.read<EditorProvider>().controller;
    final selection = controller.selection;
    if (!selection.isValid) return;

    Rect caret;
    try {
      caret = editorState.renderEditor.getLocalRectForCaret(
        TextPosition(offset: selection.extentOffset),
      );
    } catch (_) {
      return;
    }
    final viewportHeight = scroll.position.viewportDimension;
    if (viewportHeight <= 0) return;

    // Park the caret a bit above center — readers' eyes naturally rest
    // higher than geometric middle, so "true center" feels low.
    final targetY = caret.center.dy - viewportHeight * 0.42;
    final clamped = targetY.clamp(
      scroll.position.minScrollExtent,
      scroll.position.maxScrollExtent,
    );
    if ((scroll.offset - clamped).abs() < 1.5) return;
    scroll.animateTo(
      clamped,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  // ─── Link dialog (used by floating selection bar) ───
  Future<void> _openLinkDialogShortcut() async {
    final controller = context.read<EditorProvider>().controller;
    final selection = controller.selection;
    if (!selection.isValid) return;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selStyle = controller.getSelectionStyle();
    final existing =
        selStyle.attributes[Attribute.link.key]?.value as String?;
    String selectedText = '';
    if (!selection.isCollapsed) {
      final start = math.min(selection.baseOffset, selection.extentOffset);
      final end = math.max(selection.baseOffset, selection.extentOffset);
      selectedText = controller.document.getPlainText(start, end - start);
    }
    final result = await showDialog<LinkDialogResult>(
      context: context,
      builder: (ctx) => LinkDialog(
        initialText: selectedText,
        initialUrl: existing ?? '',
        canRemove: existing != null,
        isDark: isDark,
      ),
    );
    if (result == null) return;
    if (result.remove) {
      controller.formatSelection(Attribute.clone(Attribute.link, null));
      return;
    }
    final url = result.url.trim();
    if (url.isEmpty) return;
    if (selection.isCollapsed) {
      final insertText = result.text.trim().isEmpty ? url : result.text;
      final start = selection.baseOffset.clamp(0, controller.document.length);
      controller.replaceText(
        start,
        0,
        insertText,
        TextSelection.collapsed(offset: start + insertText.length),
      );
      controller.formatText(start, insertText.length, LinkAttribute(url));
    } else {
      controller.formatSelection(LinkAttribute(url));
    }
  }

  // ─── Slash menu action handler ───
  void _applySlashAction(SlashAction action) {
    final controller = context.read<EditorProvider>().controller;
    switch (action) {
      case SlashAction.h1:
        controller.formatSelection(Attribute.h1);
        break;
      case SlashAction.h2:
        controller.formatSelection(Attribute.h2);
        break;
      case SlashAction.h3:
        controller.formatSelection(Attribute.h3);
        break;
      case SlashAction.body:
        controller.formatSelection(Attribute.clone(Attribute.header, null));
        break;
      case SlashAction.bullet:
        controller.formatSelection(
            Attribute.fromKeyValue(Attribute.list.key, 'bullet')!);
        break;
      case SlashAction.numbered:
        controller.formatSelection(
            Attribute.fromKeyValue(Attribute.list.key, 'ordered')!);
        break;
      case SlashAction.checklist:
        controller.formatSelection(
            Attribute.fromKeyValue(Attribute.list.key, 'unchecked')!);
        break;
      case SlashAction.quote:
        controller.formatSelection(Attribute.blockQuote);
        break;
      case SlashAction.code:
        controller.formatSelection(Attribute.codeBlock);
        break;
      case SlashAction.divider:
        final idx = controller.selection.baseOffset;
        controller.replaceText(
          idx,
          0,
          '\n———\n',
          TextSelection.collapsed(offset: idx + 5),
        );
        break;
      case SlashAction.image:
        _insertImage();
        break;
      case SlashAction.generateNames:
        _runNameGenerator();
        break;
    }
  }

  Future<void> _runNameGenerator() async {
    final controller = context.read<EditorProvider>().controller;
    final picked = await NameGeneratorDialog.show(context);
    if (picked == null || picked.isEmpty) return;
    final selection = controller.selection;
    final start =
        selection.baseOffset.clamp(0, controller.document.length).toInt();
    controller.replaceText(
      start,
      0,
      picked,
      TextSelection.collapsed(offset: start + picked.length),
    );
  }

  // ─── Command palette (Cmd/Ctrl+K) ───
  void _openCommandPalette() {
    final controller = context.read<EditorProvider>().controller;
    final provider = context.read<EditorProvider>();

    void apply(Attribute attr) {
      controller.formatSelection(attr);
    }

    void clear(Attribute attr) {
      controller.formatSelection(Attribute.clone(attr, null));
    }

    final commands = <PaletteCommand>[
      // ── Format ──
      PaletteCommand(
        id: 'h1',
        group: 'Format',
        label: 'Heading 1',
        icon: Icons.title,
        keywords: const ['title', 'h1'],
        run: () => apply(Attribute.h1),
      ),
      PaletteCommand(
        id: 'h2',
        group: 'Format',
        label: 'Heading 2',
        icon: Icons.title,
        keywords: const ['subtitle', 'h2'],
        run: () => apply(Attribute.h2),
      ),
      PaletteCommand(
        id: 'h3',
        group: 'Format',
        label: 'Heading 3',
        icon: Icons.title,
        run: () => apply(Attribute.h3),
      ),
      PaletteCommand(
        id: 'body',
        group: 'Format',
        label: 'Body text',
        icon: Icons.notes,
        keywords: const ['paragraph'],
        run: () => clear(Attribute.header),
      ),
      PaletteCommand(
        id: 'bold',
        group: 'Format',
        label: 'Bold',
        icon: Icons.format_bold,
        shortcut: '⌘B',
        run: () => apply(Attribute.bold),
      ),
      PaletteCommand(
        id: 'italic',
        group: 'Format',
        label: 'Italic',
        icon: Icons.format_italic,
        shortcut: '⌘I',
        run: () => apply(Attribute.italic),
      ),
      PaletteCommand(
        id: 'underline',
        group: 'Format',
        label: 'Underline',
        icon: Icons.format_underline,
        shortcut: '⌘U',
        run: () => apply(Attribute.underline),
      ),
      PaletteCommand(
        id: 'strike',
        group: 'Format',
        label: 'Strikethrough',
        icon: Icons.format_strikethrough,
        run: () => apply(Attribute.strikeThrough),
      ),
      PaletteCommand(
        id: 'code',
        group: 'Format',
        label: 'Inline code',
        icon: Icons.code,
        run: () => apply(Attribute.inlineCode),
      ),
      PaletteCommand(
        id: 'quote',
        group: 'Format',
        label: 'Blockquote',
        icon: Icons.format_quote,
        run: () => apply(Attribute.blockQuote),
      ),
      PaletteCommand(
        id: 'codeblock',
        group: 'Format',
        label: 'Code block',
        icon: Icons.code,
        run: () => apply(Attribute.codeBlock),
      ),

      // ── Insert ──
      PaletteCommand(
        id: 'image',
        group: 'Insert',
        label: 'Insert image',
        icon: Icons.image,
        keywords: const ['photo', 'picture'],
        run: _insertImage,
      ),
      PaletteCommand(
        id: 'bullet',
        group: 'Insert',
        label: 'Bulleted list',
        icon: Icons.format_list_bulleted,
        run: () =>
            apply(Attribute.fromKeyValue(Attribute.list.key, 'bullet')!),
      ),
      PaletteCommand(
        id: 'numbered',
        group: 'Insert',
        label: 'Numbered list',
        icon: Icons.format_list_numbered,
        run: () =>
            apply(Attribute.fromKeyValue(Attribute.list.key, 'ordered')!),
      ),
      PaletteCommand(
        id: 'checklist',
        group: 'Insert',
        label: 'Checklist',
        icon: Icons.checklist,
        keywords: const ['todo', 'task'],
        run: () =>
            apply(Attribute.fromKeyValue(Attribute.list.key, 'unchecked')!),
      ),

      // ── View ──
      PaletteCommand(
        id: 'focus',
        group: 'View',
        label: _focusMode ? 'Exit focus mode' : 'Enter focus mode',
        icon: CupertinoIcons.eye_slash,
        keywords: const ['distraction', 'zen'],
        run: _toggleFocusMode,
      ),
      PaletteCommand(
        id: 'outline',
        group: 'View',
        label: _showOutline ? 'Hide outline' : 'Show outline',
        icon: CupertinoIcons.list_bullet_indent,
        run: () => setState(() => _showOutline = !_showOutline),
      ),
      PaletteCommand(
        id: 'find',
        group: 'View',
        label: 'Find & replace',
        icon: Icons.search,
        shortcut: kIsWeb ? null : '⌘F',
        run: () => setState(() => _findReplaceOpen = !_findReplaceOpen),
      ),
      PaletteCommand(
        id: 'mode',
        group: 'View',
        label: _isCanvasMode ? 'Switch to Write mode' : 'Switch to Creative mode',
        icon: _isCanvasMode ? CupertinoIcons.pencil : CupertinoIcons.paintbrush,
        run: () => _switchMode(!_isCanvasMode),
      ),
      PaletteCommand(
        id: 'sections',
        group: 'View',
        label: 'Toggle sections sidebar',
        icon: CupertinoIcons.sidebar_left,
        run: provider.toggleShowSections,
      ),
      PaletteCommand(
        id: 'prompt',
        group: 'View',
        label: 'Surface a writing prompt',
        icon: CupertinoIcons.lightbulb,
        run: _showRandomPrompt,
      ),

      // ── Actions ──
      PaletteCommand(
        id: 'newSection',
        group: 'Actions',
        label: 'New section',
        icon: CupertinoIcons.add,
        run: _promptNewSection,
      ),
      PaletteCommand(
        id: 'save',
        group: 'Actions',
        label: 'Save now',
        icon: CupertinoIcons.cloud_upload,
        shortcut: '⌘S',
        run: provider.forceSaveImmediately,
      ),
      PaletteCommand(
        id: 'ai',
        group: 'Actions',
        label: 'AI assist',
        icon: CupertinoIcons.wand_stars,
        run: _showAIPanel,
      ),

      // ── Jump to section ──
      for (final s in provider.allBooksSection)
        PaletteCommand(
          id: 'jump_${s.id}',
          group: 'Jump to section',
          label: s.title.isEmpty ? 'Untitled' : s.title,
          icon: CupertinoIcons.text_alignleft,
          keywords: const ['go', 'navigate'],
          run: () {
            provider.forceSaveImmediately();
            provider.setActiveSection(s);
            provider.initEditor();
            _initSessionTracking();
          },
        ),
    ];

    showCommandPalette(context: context, commands: commands);
  }

  // ─── Focus Mode ───
  void _toggleFocusMode() {
    setState(() => _focusMode = !_focusMode);
    if (_focusMode) {
      _focusModeController.forward();
      // Hide the sections sidebar
      final provider = context.read<EditorProvider>();
      if (provider.showSectionsList) {
        provider.toggleShowSections();
      }
    } else {
      _focusModeController.reverse();
    }
  }

  // ─── Paper Theme Colors ───
  Color _getPaperColor(bool isDark) => _paperColorFor(_paperTheme, isDark);

  Color _paperColorFor(PaperTheme theme, bool isDark) {
    if (isDark) {
      switch (theme) {
        case PaperTheme.defaultTheme:
          return const Color(0xFF131315);
        case PaperTheme.sepia:
          return const Color(0xFF1A1710);
        case PaperTheme.warm:
          return const Color(0xFF1A1412);
        case PaperTheme.cool:
          return const Color(0xFF101318);
        case PaperTheme.green:
          return const Color(0xFF0F1510);
        case PaperTheme.rose:
          return const Color(0xFF181014);
        case PaperTheme.midnight:
          return const Color(0xFF0A0A14);
      }
    } else {
      switch (theme) {
        case PaperTheme.defaultTheme:
          return Colors.white;
        case PaperTheme.sepia:
          return const Color(0xFFF5ECD7);
        case PaperTheme.warm:
          return const Color(0xFFFFF5EE);
        case PaperTheme.cool:
          return const Color(0xFFF0F4FA);
        case PaperTheme.green:
          return const Color(0xFFF2F7F2);
        case PaperTheme.rose:
          return const Color(0xFFFFF0F3);
        case PaperTheme.midnight:
          return const Color(0xFFEEEEF5);
      }
    }
  }

  // Visible-on-dark swatch colors for the paper theme picker. The dark-mode
  // paper colors are near-black, so the swatches would look like empty
  // squares against the sheet surface — this returns a brighter sample.
  Color _paperSwatchColor(PaperTheme theme) {
    switch (theme) {
      case PaperTheme.defaultTheme:
        return const Color(0xFFFAFAFA);
      case PaperTheme.sepia:
        return const Color(0xFFF5ECD7);
      case PaperTheme.warm:
        return const Color(0xFFFFE9D6);
      case PaperTheme.cool:
        return const Color(0xFFD8E4F5);
      case PaperTheme.green:
        return const Color(0xFFD8EBD8);
      case PaperTheme.rose:
        return const Color(0xFFF7D6DD);
      case PaperTheme.midnight:
        return const Color(0xFF2A2A40);
    }
  }

  Color _getTextColor(bool isDark) {
    if (isDark) {
      switch (_paperTheme) {
        case PaperTheme.sepia:
          return const Color(0xFFE8D5B0);
        case PaperTheme.warm:
          return const Color(0xFFEDD5C8);
        case PaperTheme.cool:
          return const Color(0xFFD0D8EA);
        case PaperTheme.green:
          return const Color(0xFFC8DCC8);
        case PaperTheme.rose:
          return const Color(0xFFE0C8D5);
        default:
          return Colors.white;
      }
    }
    switch (_paperTheme) {
      case PaperTheme.sepia:
        return const Color(0xFF3D2E1C);
      case PaperTheme.warm:
        return const Color(0xFF3A2520);
      case PaperTheme.cool:
        return const Color(0xFF1E2A3A);
      case PaperTheme.green:
        return const Color(0xFF1C2E1C);
      case PaperTheme.rose:
        return const Color(0xFF3A1E2E);
      default:
        return const Color(0xFF111111);
    }
  }

  // ─── Image Insertion (instant preview + background upload) ───
  Future<void> _insertImage() async {
    final auth = context.read<AuthProvider>();
    final editorProvider = context.read<EditorProvider>();
    if (auth.currentUser == null) return;

    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    final bytes = await picked.readAsBytes();
    if (!mounted) return;

    final dataUri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    final controller = editorProvider.controller;
    final index = controller.selection.baseOffset;
    final length = controller.selection.extentOffset - index;
    if (length > 0) {
      controller.replaceText(index, length, '', null);
    }
    controller.document.insert(index, BlockEmbed.image(dataUri));
    controller.updateSelection(
      TextSelection.collapsed(offset: index + 1),
      ChangeSource.local,
    );

    setState(() => _imageUploading = true);
    _uploadAndReplace(
      editorProvider: editorProvider,
      userId: auth.currentUser!.id,
      bytes: bytes,
      tempUri: dataUri,
    );
  }

  Future<void> _uploadAndReplace({
    required EditorProvider editorProvider,
    required String userId,
    required Uint8List bytes,
    required String tempUri,
  }) async {
    try {
      final auth = context.read<AuthProvider>();
      final result = await auth.storageService.uploadEditorImage(
        userId,
        bytes,
      );
      final url = result.url;
      if (!mounted) return;

      final delta = editorProvider.controller.document.toDelta();
      final ops = delta.toJson();
      bool replaced = false;
      for (final op in ops) {
        final insert = op['insert'];
        if (insert is Map) {
          final embed = insert;
          final imgVal = embed['image'];
          if (imgVal is String) {
            final hashIdx = imgVal.indexOf('#');
            final base = hashIdx == -1 ? imgVal : imgVal.substring(0, hashIdx);
            final frag = hashIdx == -1 ? '' : imgVal.substring(hashIdx);
            if (base == tempUri) {
              embed['image'] = '$url$frag';
              replaced = true;
              break;
            }
          }
        }
      }
      if (replaced) {
        final sel = editorProvider.controller.selection;
        editorProvider.controller.document = Document.fromJson(ops);
        editorProvider.controller.updateSelection(sel, ChangeSource.local);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Image upload failed — will retry on save'),
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _imageUploading = false);
    }
  }

  // ─── Mode Toggle ───
  void _switchMode(bool toCanvas) {
    if (toCanvas == _isCanvasMode) return;
    final provider = context.read<EditorProvider>();
    if (toCanvas) {
      provider.forceSaveImmediately();
    } else {
      _saveCanvasData();
    }
    setState(() => _isCanvasMode = toCanvas);
  }

  void _saveCanvasData() {
    final provider = context.read<EditorProvider>();
    if (provider.activeSection != null) {
      provider.forceSaveImmediately();
    }
  }

  Widget _modeTab({
    required String label,
    required IconData icon,
    required bool isActive,
    required Color textColor,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    final activeColor =
        isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isActive ? activeColor.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13,
              color:
                  isActive ? activeColor : textColor.withValues(alpha: 0.35),
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color:
                    isActive ? activeColor : textColor.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── AI Panel ───
  Future<void> _showAIPanel() async {
    final editorProvider = context.read<EditorProvider>();
    final controller = editorProvider.controller;

    final selection = controller.selection;
    final hasSelection = selection.baseOffset != selection.extentOffset;

    final int replaceIndex;
    final int replaceLength;
    if (hasSelection) {
      replaceIndex = selection.baseOffset;
      replaceLength = selection.extentOffset - selection.baseOffset;
    } else {
      replaceIndex = 0;
      // Whole document minus its mandatory trailing newline.
      replaceLength = controller.document.length - 1;
    }

    final sourceDelta = controller.document
        .toDelta()
        .slice(replaceIndex, replaceIndex + replaceLength);
    final sourceJson = sourceDelta.toJson();
    final plainText = hasSelection
        ? controller.document.getPlainText(replaceIndex, replaceLength)
        : controller.document.toPlainText().trim();

    if (plainText.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Write some text first, then use AI to enhance it.',
            style: GoogleFonts.inter(),
          ),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    // Did the source range end in a paragraph break? If not, the merged
    // delta's trailing `\n` would split the user's paragraph in two; strip it
    // on apply.
    final sourceEndsWithNewline = _deltaEndsWithNewline(sourceDelta);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final baseTextColor =
        isDark ? Colors.white : const Color(0xFF1A1A1A);
    final themedTextColor = _paperTheme == PaperTheme.defaultTheme
        ? baseTextColor
        : _getTextColor(isDark);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.45);
    final surfaceColor =
        isDark ? const Color(0xFF141414) : const Color(0xFFF5F5F7);
    final sheetBackground =
        isDark ? const Color(0xFF0D0D0D) : Colors.white;

    final action = await showModalBottomSheet<AIAction>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: sheetBackground,
      barrierColor: Colors.black.withValues(alpha: isDark ? 0.55 : 0.35),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (sheetCtx) {
        return ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetCtx).size.height * 0.85,
          ),
          child: AIActionPicker(
            hasSelection: hasSelection,
            isDark: isDark,
            textColor: themedTextColor,
            mutedColor: mutedColor,
            surfaceColor: surfaceColor,
            backgroundColor: sheetBackground,
          ),
        );
      },
    );

    if (action == null || !mounted) return;

    setState(() {
      _aiPanel = _AIPanelData(
        action: action,
        sourceDelta: sourceJson,
        plainText: plainText,
        hasSelection: hasSelection,
        replaceIndex: replaceIndex,
        replaceLength: replaceLength,
        sourceEndsWithNewline: sourceEndsWithNewline,
      );
    });
  }

  void _closeAIPanel() {
    if (_aiPanel != null) setState(() => _aiPanel = null);
  }

  bool _deltaEndsWithNewline(Delta delta) {
    final ops = delta.toList();
    if (ops.isEmpty) return false;
    final last = ops.last.data;
    return last is String && last.endsWith('\n');
  }

  void _applyMergedDelta(
    QuillController controller,
    List<dynamic> mergedJson,
    int replaceIndex,
    int replaceLength, {
    required bool stripTrailingNewline,
  }) {
    // Scrivener-class auto-snapshot: capture pre-AI state so the user can
    // restore if the rewrite goes sideways. Awaiting the future would
    // delay the apply by one frame; fire-and-forget is fine because the
    // version provider uses last-write-wins on disk.
    unawaited(context
        .read<VersionHistoryProvider>()
        .captureManual(controller, label: 'Before AI rewrite'));
    var newDelta = Delta.fromJson(mergedJson);

    if (stripTrailingNewline) {
      final ops = newDelta.toList();
      if (ops.isNotEmpty) {
        final last = ops.last;
        final data = last.data;
        if (data is String && data == '\n' && last.attributes == null) {
          ops.removeLast();
          newDelta = Delta.fromOperations(ops);
        }
      }
    }

    final transform = Delta();
    if (replaceIndex > 0) transform.retain(replaceIndex);
    if (replaceLength > 0) transform.delete(replaceLength);
    for (final op in newDelta.toList()) {
      transform.push(op);
    }

    var insertedLen = 0;
    for (final op in newDelta.toList()) {
      final data = op.data;
      if (data is String) insertedLen += data.length;
    }

    controller.compose(
      transform,
      TextSelection.collapsed(offset: replaceIndex + insertedLen),
      ChangeSource.local,
    );
  }

  // ─── Document Outline ───
  List<OutlineHeading> _extractOutline() {
    final provider = context.read<EditorProvider>();
    final doc = provider.controller.document;
    final headings = <OutlineHeading>[];

    int offset = 0;
    for (final op in doc.toDelta().toList()) {
      final data = op.data;
      final attrs = op.attributes;
      if (data is String) {
        if (attrs != null && attrs.containsKey('header')) {
          final level = attrs['header'] as int;
          final text = data.trim();
          if (text.isNotEmpty) {
            headings.add(OutlineHeading(
              text: text,
              level: level,
              offset: offset,
            ));
          }
        }
        offset += data.length;
      } else {
        offset += 1;
      }
    }

    // Fallback: scan line by line
    if (headings.isEmpty) {
      final lines = doc.toPlainText().split('\n');
      int pos = 0;
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.length > 2 && trimmed.length < 80) {
          // Check if this position has header attribute
          if (pos < doc.length) {
            try {
              final style = doc.collectStyle(pos, 0);
              final headerAttr = style.attributes[Attribute.header.key];
              if (headerAttr != null && headerAttr.value != null) {
                headings.add(OutlineHeading(
                  text: trimmed,
                  level: headerAttr.value as int,
                  offset: pos,
                ));
              }
            } catch (_) {}
          }
        }
        pos += line.length + 1;
      }
    }

    return headings;
  }

  void _jumpToOffset(int offset) {
    final provider = context.read<EditorProvider>();
    provider.controller.updateSelection(
      TextSelection.collapsed(offset: offset.clamp(0, provider.controller.document.length - 1)),
      ChangeSource.local,
    );
  }

  // ─── Writing Prompt ───
  void _showRandomPrompt() {
    final random = math.Random();
    setState(() {
      _activePrompt = writingPrompts[random.nextInt(writingPrompts.length)];
    });
    Future.delayed(const Duration(seconds: 12), () {
      if (mounted && _activePrompt != null) {
        setState(() => _activePrompt = null);
      }
    });
  }

  // ─── Writer Settings Sheet ───
  void _showWriterSettings() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.45);
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final surfaceColor =
        isDark ? const Color(0xFF141414) : const Color(0xFFF5F5F7);

    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _escapeDismiss(
        ctx,
        StatefulBuilder(
        builder: (ctx, setSheetState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(top: 8, bottom: 12),
                    decoration: BoxDecoration(
                      color: textColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header
                        Row(
                          children: [
                            Iconify(
                              Carbon.pending,
                              size: 20,
                              color: textColor,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Writer Settings',
                              style: GoogleFonts.inter(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // ── Appearance ──
                        Text(
                          'APPEARANCE',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Consumer<SettingsProvider>(
                          builder: (_, settings, _) {
                            final darkActive =
                                settings.themeMode == ThemeMode.dark ||
                                    (settings.themeMode == ThemeMode.system &&
                                        Theme.of(ctx).brightness ==
                                            Brightness.dark);
                            return _settingsToggle(
                              icon: CupertinoIcons.moon,
                              label: 'Dark Mode',
                              subtitle:
                                  'Switch the app between light and dark theme',
                              value: darkActive,
                              textColor: textColor,
                              mutedColor: mutedColor,
                              surfaceColor: surfaceColor,
                              isDark: isDark,
                              onChanged: (v) {
                                settings.toggleTheme(v);
                                Navigator.pop(ctx);
                              },
                            );
                          },
                        ),

                        const SizedBox(height: 24),

                        // ── Writing Modes ──
                        Text(
                          'WRITING MODES',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _settingsToggle(
                          icon: CupertinoIcons.eye_slash,
                          label: 'Focus Mode',
                          subtitle: 'Hide everything except your words',
                          value: _focusMode,
                          textColor: textColor,
                          mutedColor: mutedColor,
                          surfaceColor: surfaceColor,
                          isDark: isDark,
                          onChanged: (v) {
                            setSheetState(() {});
                            _toggleFocusMode();
                            Navigator.pop(ctx);
                          },
                        ),
                        const SizedBox(height: 8),
                        _settingsToggle(
                          icon: CupertinoIcons.text_cursor,
                          label: 'Typewriter Mode',
                          subtitle: 'Keep the active line centered',
                          value: _typewriterMode,
                          textColor: textColor,
                          mutedColor: mutedColor,
                          surfaceColor: surfaceColor,
                          isDark: isDark,
                          onChanged: (v) {
                            setSheetState(() {});
                            setState(() => _typewriterMode = v);
                            final controller =
                                context.read<EditorProvider>().controller;
                            if (v) {
                              _attachTypewriterListenerIfNeeded(controller);
                              _scheduleTypewriterRecenter();
                            } else {
                              _detachTypewriterListener();
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        _settingsToggle(
                          icon: CupertinoIcons.waveform,
                          label: 'Typing Haptics',
                          subtitle:
                              'Soft tap at sentence and paragraph breaks',
                          value: context
                              .read<EditorProvider>()
                              .typingHapticsEnabled,
                          textColor: textColor,
                          mutedColor: mutedColor,
                          surfaceColor: surfaceColor,
                          isDark: isDark,
                          onChanged: (v) {
                            setSheetState(() {});
                            context
                                .read<EditorProvider>()
                                .setTypingHapticsEnabled(v);
                          },
                        ),
                        const SizedBox(height: 8),
                        _settingsToggle(
                          icon: CupertinoIcons.textformat_alt,
                          label: 'Smart Punctuation',
                          subtitle:
                              'Curl quotes, em dashes, and ellipsis as you type',
                          value: context
                              .read<EditorProvider>()
                              .smartPunctuationEnabled,
                          textColor: textColor,
                          mutedColor: mutedColor,
                          surfaceColor: surfaceColor,
                          isDark: isDark,
                          onChanged: (v) {
                            setSheetState(() {});
                            context
                                .read<EditorProvider>()
                                .setSmartPunctuationEnabled(v);
                          },
                        ),

                        const SizedBox(height: 24),

                        // ── Paper Theme ──
                        Text(
                          'PAPER THEME',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: PaperTheme.values.map((theme) {
                            final isActive = _paperTheme == theme;
                            final swatch = _paperSwatchColor(theme);
                            return GestureDetector(
                              onTap: () {
                                setSheetState(() {});
                                setState(() => _paperTheme = theme);
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 200),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 9),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? (isDark
                                          ? const Color(0xFF5B8DEF)
                                              .withValues(alpha: 0.18)
                                          : const Color(0xFF5B8DEF)
                                              .withValues(alpha: 0.10))
                                      : surfaceColor,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: isActive
                                        ? const Color(0xFF5B8DEF)
                                            .withValues(alpha: 0.55)
                                        : Colors.transparent,
                                    width: 1.5,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: swatch,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: isDark
                                              ? Colors.white
                                                  .withValues(alpha: 0.18)
                                              : Colors.black
                                                  .withValues(alpha: 0.12),
                                        ),
                                      ),
                                      child: isActive
                                          ? Icon(
                                              CupertinoIcons.checkmark_alt,
                                              size: 10,
                                              color: theme ==
                                                      PaperTheme.midnight
                                                  ? Colors.white
                                                  : Colors.black87,
                                            )
                                          : null,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      theme.label,
                                      style: GoogleFonts.inter(
                                        fontSize: 13,
                                        fontWeight: isActive
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: isActive
                                            ? const Color(0xFF5B8DEF)
                                            : textColor
                                                .withValues(alpha: 0.75),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
                        ),

                        const SizedBox(height: 24),

                        // ── Daily Goal ──
                        Text(
                          'DAILY WORD GOAL',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: surfaceColor,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(CupertinoIcons.flame,
                                      size: 18, color: Colors.orange),
                                  const SizedBox(width: 8),
                                  Text(
                                    '$_dailyGoal words',
                                    style: GoogleFonts.inter(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: textColor,
                                    ),
                                  ),
                                  const Spacer(),
                                  CupertinoSwitch(
                                    value: _showGoalWidget,
                                    onChanged: (v) {
                                      setSheetState(() {});
                                      setState(() => _showGoalWidget = v);
                                      _persistGoalSetting(
                                        promptForPermission: v,
                                      );
                                    },
                                    activeTrackColor: const Color(0xFF5B8DEF),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  for (final goal
                                      in [250, 500, 1000, 1500, 2000])
                                    Expanded(
                                      child: GestureDetector(
                                        onTap: () {
                                          setSheetState(() {});
                                          _applyGoalChange(goal);
                                        },
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                              milliseconds: 180),
                                          margin: const EdgeInsets.symmetric(
                                              horizontal: 3),
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 10),
                                          decoration: BoxDecoration(
                                            color: _dailyGoal == goal
                                                ? const Color(0xFF5B8DEF)
                                                    .withValues(alpha: 0.18)
                                                : isDark
                                                    ? Colors.white.withValues(
                                                        alpha: 0.05)
                                                    : Colors.black.withValues(
                                                        alpha: 0.04),
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            border: Border.all(
                                              color: _dailyGoal == goal
                                                  ? const Color(0xFF5B8DEF)
                                                      .withValues(alpha: 0.5)
                                                  : Colors.transparent,
                                              width: 1.2,
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              '$goal',
                                              style: GoogleFonts.inter(
                                                fontSize: 12.5,
                                                fontWeight: _dailyGoal == goal
                                                    ? FontWeight.w700
                                                    : FontWeight.w600,
                                                color: _dailyGoal == goal
                                                    ? const Color(0xFF5B8DEF)
                                                    : mutedColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  GestureDetector(
                                    onTap: () async {
                                      final v = await _promptCustomGoal();
                                      if (v == null) return;
                                      setSheetState(() {});
                                      _applyGoalChange(v);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 12, vertical: 6),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: textColor.withValues(
                                              alpha: 0.12),
                                          width: 1,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(CupertinoIcons.pencil,
                                              size: 11,
                                              color: mutedColor),
                                          const SizedBox(width: 5),
                                          Text(
                                            'Custom',
                                            style: GoogleFonts.inter(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: mutedColor,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: () async {
                                      final picked =
                                          await _pickReminderTime();
                                      if (picked == null) return;
                                      setSheetState(() {});
                                      setState(() {
                                        _reminderHour = picked.hour;
                                        _reminderMinute = picked.minute;
                                      });
                                      await _goalService.setReminderTime(
                                        hour: picked.hour,
                                        minute: picked.minute,
                                      );
                                      _refreshGoalReminder();
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(CupertinoIcons.bell,
                                            size: 12,
                                            color: mutedColor),
                                        const SizedBox(width: 5),
                                        Text(
                                          'Remind at ${_formatReminderTime()}',
                                          style: GoogleFonts.inter(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            color: mutedColor,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              if (_streak > 0 || _weekTotalWords() > 0) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    if (_streak > 0) ...[
                                      Icon(CupertinoIcons.flame_fill,
                                          size: 12, color: Colors.orange),
                                      const SizedBox(width: 5),
                                      Text(
                                        '$_streak-day streak',
                                        style: GoogleFonts.inter(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.orange,
                                        ),
                                      ),
                                      Text('  ·  ',
                                          style: GoogleFonts.inter(
                                            fontSize: 11,
                                            color: mutedColor,
                                          )),
                                    ],
                                    Text(
                                      'This week: ${_weekTotalWords()} words',
                                      style: GoogleFonts.inter(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: mutedColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 22),
                        Text(
                          'EDITING ASSIST',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Consumer<SpellCheckProvider>(
                          builder: (_, sp, _) => _settingsToggle(
                            icon: CupertinoIcons.checkmark_seal,
                            label: 'Spell check',
                            subtitle:
                                'Underline misspellings and suggest fixes (offline)',
                            value: sp.enabled,
                            textColor: textColor,
                            mutedColor: mutedColor,
                            surfaceColor: surfaceColor,
                            isDark: isDark,
                            onChanged: (v) {
                              setSheetState(() {});
                              sp.setEnabled(v);
                            },
                          ),
                        ),

                        const SizedBox(height: 22),
                        Text(
                          'DOCUMENT',
                          style: GoogleFonts.inter(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: mutedColor,
                            letterSpacing: 1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Navigator.pop(ctx);
                            _showVersionHistory();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: surfaceColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(CupertinoIcons.clock,
                                    size: 18, color: textColor),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Version history',
                                        style: GoogleFonts.inter(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Browse and restore earlier snapshots of this section',
                                        style: GoogleFonts.inter(
                                          fontSize: 11.5,
                                          color: mutedColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(CupertinoIcons.chevron_right,
                                    size: 14, color: mutedColor),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () {
                            Navigator.pop(ctx);
                            _saveManualVersion();
                          },
                          child: Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: surfaceColor,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Icon(CupertinoIcons.bookmark,
                                    size: 18, color: textColor),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Save current as named version',
                                    style: GoogleFonts.inter(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  Widget _settingsToggle({
    required IconData icon,
    required String label,
    required String subtitle,
    required bool value,
    required Color textColor,
    required Color mutedColor,
    required Color surfaceColor,
    required bool isDark,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: textColor.withValues(alpha: 0.7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                ),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: mutedColor,
                  ),
                ),
              ],
            ),
          ),
          CupertinoSwitch(
            value: value,
            onChanged: onChanged,
            activeTrackColor: const Color(0xFF5B8DEF),
          ),
        ],
      ),
    );
  }

  // ─── Build ───
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = _getPaperColor(isDark);
    final surfaceColor =
        isDark ? const Color(0xFF111111) : const Color(0xFFF2F2F5);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.4)
        : Colors.black.withValues(alpha: 0.4);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final isMobile = Breakpoints.isMobile(MediaQuery.sizeOf(context).width);

    // Reload annotations whenever the active section changes. Using
    // context.select keeps this rebuild-cheap — only fires when id changes.
    // Gated on _isReady: initEditor() replaces EditorProvider.controller,
    // so syncing earlier would attach providers to a soon-orphaned instance.
    final activeSection =
        context.select<EditorProvider, SectionModel?>((p) => p.activeSection);
    if (_isReady &&
        (activeSection?.id != _annotationSectionId ||
            activeSection?.id != _versionSectionId ||
            activeSection?.id != _spellSectionId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _syncAnnotationSection(activeSection);
        _syncVersionSection(activeSection);
        _syncSpellSection(activeSection);
        _attachTypewriterListenerIfNeeded(
          context.read<EditorProvider>().controller,
        );
      });
    }

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        context.read<EditorProvider>().forceSaveImmediately();
      },
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
              setState(() => _viewMode = EditorViewMode.draft),
          const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
              setState(() => _viewMode = EditorViewMode.cards),
          const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
              setState(() => _viewMode = EditorViewMode.outline),
          const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
              setState(() => _viewMode = EditorViewMode.draft),
          const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
              setState(() => _viewMode = EditorViewMode.cards),
          const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
              setState(() => _viewMode = EditorViewMode.outline),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
        backgroundColor: bgColor,
        body: SafeArea(
          child: _isReady
              ? Stack(
                    children: [
                      Column(
                        children: [
                          // ── Top Bar ──
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 400),
                            curve: Curves.easeOutCubic,
                            height: _focusMode ? 0 : 52,
                            clipBehavior: Clip.hardEdge,
                            decoration: const BoxDecoration(),
                            child: _buildTopBar(
                              isDark: isDark,
                              bgColor: bgColor,
                              textColor: textColor,
                              mutedColor: mutedColor,
                              borderColor: borderColor,
                              isMobile: isMobile,
                            ),
                          ),

                          // ── Toolbar (only in Write mode) ──
                          // Desktop keeps the unified toolbar at the top.
                          // Mobile splits: secondary actions (image / AI /
                          // prompt / outline / focus / settings) at the
                          // top, formatting toolbar pinned to the bottom
                          // above the keyboard so it doesn't compete with
                          // the writing surface.
                          if (!_isCanvasMode && !_focusMode) ...[
                            if (!isMobile)
                              _buildDesktopToolbar(
                                isDark: isDark,
                                bgColor: bgColor,
                                textColor: textColor,
                                mutedColor: mutedColor,
                                borderColor: borderColor,
                                surfaceColor: surfaceColor,
                              ),
                            if (isMobile)
                              _buildMobileTopActions(
                                isDark: isDark,
                                bgColor: bgColor,
                                textColor: textColor,
                                borderColor: borderColor,
                              ),
                          ],

                          // ── Main Workspace ──
                          Expanded(
                            child: _isCanvasMode
                                ? Row(
                                    children: [
                                      if (!isMobile && !_focusMode)
                                        _buildSidebar(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                        ),
                                      Expanded(
                                        child: _buildCanvasMode(
                                          isDark: isDark,
                                          bgColor: bgColor,
                                          textColor: textColor,
                                        ),
                                      ),
                                    ],
                                  )
                                : Row(
                                    children: [
                                      if (!isMobile && !_focusMode)
                                        _buildSidebar(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                        ),
                                      // ── Outline Panel ──
                                      if (_showOutline && !isMobile && !_focusMode)
                                        _buildOutlinePanel(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                        ),
                                      Expanded(
                                        child: Column(
                                          children: [
                                            if (!_focusMode)
                                              Padding(
                                                padding: const EdgeInsets
                                                        .symmetric(
                                                    horizontal: 16,
                                                    vertical: 6),
                                                child: Row(
                                                  children: [
                                                    ViewSwitcher(
                                                      mode: _viewMode,
                                                      onChanged: (m) =>
                                                          setState(() =>
                                                              _viewMode = m),
                                                    ),
                                                    const Spacer(),
                                                    if (!isMobile)
                                                      IconButton(
                                                        tooltip: _showSplitView
                                                            ? 'Hide split view'
                                                            : 'Split view',
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
                                                        iconSize: 16,
                                                        icon: Icon(
                                                          _showSplitView
                                                              ? CupertinoIcons
                                                                  .rectangle_compress_vertical
                                                              : CupertinoIcons
                                                                  .square_split_2x1,
                                                          color: textColor
                                                              .withValues(
                                                                  alpha:
                                                                      _showSplitView
                                                                          ? 1
                                                                          : 0.55),
                                                        ),
                                                        onPressed: () =>
                                                            setState(() =>
                                                                _showSplitView =
                                                                    !_showSplitView),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                            if (_findReplaceOpen && !_focusMode)
                                              FindReplaceBar(
                                                controller: context
                                                    .read<EditorProvider>()
                                                    .controller,
                                                isDark: isDark,
                                                textColor: textColor,
                                                borderColor: borderColor,
                                                bgColor: bgColor,
                                                onClose: () => setState(() =>
                                                    _findReplaceOpen = false),
                                              ),
                                            Expanded(
                                              child: Stack(
                                                children: [
                                                  if (_viewMode ==
                                                          EditorViewMode
                                                              .draft ||
                                                      _focusMode)
                                                    _buildEditorArea(
                                                      isDark: isDark,
                                                      bgColor: bgColor,
                                                      textColor: textColor,
                                                      isMobile: isMobile,
                                                    )
                                                  else if (_viewMode ==
                                                      EditorViewMode.cards)
                                                    Container(
                                                      color: bgColor,
                                                      child: const CardsView(),
                                                    )
                                                  else
                                                    Container(
                                                      color: bgColor,
                                                      child:
                                                          const OutlineView(),
                                                    ),
                                                  if (!isMobile)
                                                    Positioned(
                                                      top: 0,
                                                      left: 0,
                                                      right: 0,
                                                      child: Center(
                                                        child: Column(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            FloatingFormatBar(
                                                              controller: context
                                                                  .read<
                                                                      EditorProvider>()
                                                                  .controller,
                                                              isDark: isDark,
                                                              onOpenLink:
                                                                  _openLinkDialogShortcut,
                                                              onAI: _showAIPanel,
                                                              onComment:
                                                                  _addAnnotationFromSelection,
                                                            ),
                                                            InlineSpellCheckBar(
                                                              controller: context
                                                                  .read<
                                                                      EditorProvider>()
                                                                  .controller,
                                                              isDark: isDark,
                                                              onReplace:
                                                                  _replaceMisspelling,
                                                              onAddToDictionary:
                                                                  (m) => context
                                                                      .read<
                                                                          SpellCheckProvider>()
                                                                      .addToDictionary(
                                                                          m.word),
                                                              onIgnore: (m) =>
                                                                  context
                                                                      .read<
                                                                          SpellCheckProvider>()
                                                                      .dismissIssue(
                                                                          m),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  // Side pill is desktop-only:
                                                  // on mobile it covered the
                                                  // writing surface, so those
                                                  // actions live in the new
                                                  // top-actions row instead.
                                                  if (!_focusMode && !isMobile)
                                                    Positioned(
                                                      top: 60,
                                                      right: 28,
                                                      child: Consumer<
                                                          AnnotationProvider>(
                                                        builder: (_, ann, _) =>
                                                            SideActionsPill(
                                                          isDark: isDark,
                                                          outlineActive:
                                                              _showOutline,
                                                          focusActive:
                                                              _focusMode,
                                                          annotationsActive:
                                                              _showAnnotations,
                                                          annotationCount:
                                                              ann.unresolvedCount,
                                                          onAI: _showAIPanel,
                                                          onPrompt:
                                                              _showRandomPrompt,
                                                          onToggleOutline: () =>
                                                              setState(() =>
                                                                  _showOutline =
                                                                      !_showOutline),
                                                          onToggleFocus:
                                                              _toggleFocusMode,
                                                          onToggleAnnotations:
                                                              () => setState(
                                                                  () => _showAnnotations =
                                                                      !_showAnnotations),
                                                          onVersionHistory:
                                                              _showVersionHistory,
                                                          inspectorActive:
                                                              _showInspector,
                                                          onToggleInspector:
                                                              () => setState(
                                                                  () => _showInspector =
                                                                      !_showInspector),
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (_showAnnotations &&
                                          !isMobile &&
                                          !_focusMode)
                                        AnnotationsPanel(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                          onJump: _jumpToAnnotation,
                                          onResolveToggle: (a) => context
                                              .read<AnnotationProvider>()
                                              .setResolved(a.id, !a.resolved),
                                          onDelete: _deleteAnnotation,
                                          onClose: () => setState(() =>
                                              _showAnnotations = false),
                                        ),
                                      if (_showInspector &&
                                          !isMobile &&
                                          !_focusMode)
                                        SectionInspector(
                                          isDark: isDark,
                                          textColor: textColor,
                                          borderColor: borderColor,
                                          surfaceColor: surfaceColor,
                                          onClose: () => setState(() =>
                                              _showInspector = false),
                                        ),
                                      if (_showSplitView &&
                                          !isMobile &&
                                          !_focusMode)
                                        SecondaryPane(
                                          width: _splitViewWidth,
                                          onWidthChanged: (w) => setState(
                                              () => _splitViewWidth = w),
                                          onClose: () => setState(() =>
                                              _showSplitView = false),
                                        ),
                                    ],
                                  ),
                          ),

                          // ── Mobile inline spell check bar ──
                          // Sits above the formatting toolbar (and the
                          // keyboard) when the caret is inside a misspelled
                          // word. Self-hides otherwise — Center with
                          // heightFactor: 1.0 collapses to 0 when the inner
                          // bar returns SizedBox.shrink(), so the toolbar
                          // doesn't get pushed up by an empty row.
                          if (isMobile && !_isCanvasMode && !_focusMode)
                            Center(
                              heightFactor: 1.0,
                              child: InlineSpellCheckBar(
                                controller: context
                                    .read<EditorProvider>()
                                    .controller,
                                isDark: isDark,
                                onReplace: _replaceMisspelling,
                                onAddToDictionary: (m) => context
                                    .read<SpellCheckProvider>()
                                    .addToDictionary(m.word),
                                onIgnore: (m) => context
                                    .read<SpellCheckProvider>()
                                    .dismissIssue(m),
                              ),
                            ),

                          // ── Mobile formatting toolbar (BOTTOM) ──
                          // Anchored above the keyboard via Scaffold's
                          // resizeToAvoidBottomInset (default true).
                          if (isMobile && !_isCanvasMode && !_focusMode)
                            _buildMobileToolbar(
                              isDark: isDark,
                              bgColor: bgColor,
                              textColor: textColor,
                              borderColor: borderColor,
                            ),

                          // ── Status Bar ──
                          if (!_isCanvasMode && !_focusMode)
                            _buildStatusBar(
                              bgColor: bgColor,
                              textColor: textColor,
                              borderColor: borderColor,
                              mutedColor: mutedColor,
                              isDark: isDark,
                            ),
                        ],
                      ),

                      // ── Writing Prompt Overlay ──
                      if (_activePrompt != null)
                        _buildPromptOverlay(
                          isDark: isDark,
                          textColor: textColor,
                          isMobile: isMobile,
                        ),

                      // ── Daily Goal Progress Widget ──
                      if (_showGoalWidget && !_isCanvasMode && !_focusMode)
                        _buildGoalWidget(
                          isDark: isDark,
                          textColor: textColor,
                          isMobile: isMobile,
                        ),

                      // ── Focus Mode Exit Button ──
                      if (_focusMode)
                        Positioned(
                          top: 14,
                          right: 16,
                          child: FadeTransition(
                            opacity: _focusModeAnimation,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                FocusExitButton(
                                  isDark: isDark,
                                  onTap: _toggleFocusMode,
                                ),
                                const SizedBox(height: 8),
                                Padding(
                                  padding:
                                      const EdgeInsets.only(right: 4),
                                  child: FocusWordCounter(
                                    isDark: isDark,
                                    sessionStart: _sessionStartWords,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                    ],
                  )
              : const Center(child: AppSpinner(size: 28)),
        ),
      ),
        ),
      ),
    );
  }

  // ─── Top Bar ───
  Widget _buildTopBar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color mutedColor,
    required Color borderColor,
    required bool isMobile,
  }) {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Back
          IconButton(
            icon: Icon(CupertinoIcons.arrow_left, size: 20, color: textColor),
            onPressed: () {
              context.read<EditorProvider>().forceSaveImmediately();
              Navigator.pop(context);
            },
          ),

          const SizedBox(width: 4),

          // Section title — narrowly scoped so typing-burst notifies don't
          // rebuild this subtree.
          Expanded(
            child: Selector<EditorProvider, String>(
              selector: (_, p) => p.activeSection?.title ?? '',
              builder: (context, title, _) {
                return Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),

          // Write / Creative mode toggle
          Container(
            height: 30,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _modeTab(
                  label: 'Write',
                  icon: CupertinoIcons.pencil,
                  isActive: !_isCanvasMode,
                  textColor: textColor,
                  isDark: isDark,
                  onTap: () => _switchMode(false),
                ),
                _modeTab(
                  label: 'Creative',
                  icon: CupertinoIcons.paintbrush,
                  isActive: _isCanvasMode,
                  textColor: textColor,
                  isDark: isDark,
                  onTap: () => _switchMode(true),
                ),
              ],
            ),
          ),

          const SizedBox(width: 6),

          // New Section
          if (isMobile)
            ToolbarIconButton(
              icon: CupertinoIcons.add,
              tooltip: 'New Section',
              color: textColor,
              onPressed: _promptNewSection,
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 4, right: 6),
              child: CupertinoButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: textColor,
                borderRadius: BorderRadius.circular(10),
                minimumSize: Size.zero,
                onPressed: _promptNewSection,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(CupertinoIcons.add, size: 13, color: bgColor),
                    const SizedBox(width: 5),
                    Text(
                      'New Section',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: bgColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Sync Status Chip ───
  // Icon-only, sized to match ToolbarIconButton (size 19, 36×36 hitbox).
  // Status name shows in the tooltip; color carries the state.
  // Driven off outbox depth + connectivity — listens to a small
  // ValueListenable + the two outbox counters so it flips "Saved → Typing"
  // without rebuilding the rest of the editor scaffold on each keystroke.
  Widget _buildSyncStatusChip({required Color mutedColor}) {
    final provider = context.read<EditorProvider>();
    return ListenableBuilder(
      listenable: Listenable.merge([
        provider.syncStatusListenable,
        provider.pendingOpsCount,
        provider.failedOpsCount,
      ]),
      builder: (context, _) {
        final status = provider.syncStatusListenable.value;
        final pending = provider.pendingOpsCount.value;
        final failed = provider.failedOpsCount.value;
        IconData icon;
        Color iconColor;
        String tooltip;
        switch (status) {
          case SyncStatus.idle:
            icon = CupertinoIcons.cloud;
            iconColor = Colors.green.withValues(alpha: 0.8);
            tooltip = 'Saved';
            break;
          case SyncStatus.typing:
            icon = CupertinoIcons.pencil;
            iconColor = Colors.amber.withValues(alpha: 0.9);
            tooltip = 'Typing';
            break;
          case SyncStatus.saving:
            icon = CupertinoIcons.cloud_upload;
            iconColor = mutedColor;
            tooltip = 'Saving';
            break;
          case SyncStatus.offline:
            icon = CupertinoIcons.wifi_slash;
            iconColor = Colors.amber.withValues(alpha: 0.9);
            tooltip = 'Offline · $pending pending';
            break;
          case SyncStatus.syncing:
            icon = CupertinoIcons.arrow_2_circlepath;
            iconColor = mutedColor;
            tooltip = 'Syncing $pending';
            break;
          case SyncStatus.error:
            icon = CupertinoIcons.exclamationmark_circle;
            iconColor = Colors.red.withValues(alpha: 0.9);
            tooltip = '$failed failed — tap to review';
            break;
        }

        final inner = Icon(icon, size: 19, color: iconColor);

        final chip = Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Center(child: inner),
          ),
        );

        Widget result = chip;
        if (status == SyncStatus.error) {
          result = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _showFailedOpsSheet(context, provider),
            child: chip,
          );
        }

        if (!_imageUploading) return result;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Tooltip(
              message: 'Uploading image',
              child: SizedBox(
                width: 36,
                height: 36,
                child: Center(child: AppSpinner(size: 14)),
              ),
            ),
            result,
          ],
        );
      },
    );
  }

  // ─── Desktop Toolbar ───
  Widget _buildDesktopToolbar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color mutedColor,
    required Color borderColor,
    required Color surfaceColor,
  }) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Row(
        children: [
          // Image insert
          ToolbarIconButton(
            iconWidget: Iconify(
              Ph.google_photos_logo_bold,
              size: 19,
              color: textColor,
            ),
            tooltip: 'Insert Image',
            color: textColor,
            onPressed: _insertImage,
          ),

          // Sections sidebar toggle — paired with the image insert so the
          // top bar stays focused on title + status + new section.
          ToolbarIconButton(
            icon: context.select<EditorProvider, bool>(
                    (p) => p.showSectionsList)
                ? CupertinoIcons.sidebar_left
                : CupertinoIcons.sidebar_right,
            tooltip: 'Toggle sections sidebar',
            color: textColor,
            onPressed: () =>
                context.read<EditorProvider>().toggleShowSections(),
          ),

          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: borderColor,
          ),

          // Quill toolbar
          Expanded(
            child: _buildQuillToolbar(isDark: isDark, textColor: textColor),
          ),

          Container(
            width: 1,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: borderColor,
          ),

          _buildSyncStatusChip(mutedColor: mutedColor),

          // Writer Settings (paper themes / typewriter / goal etc.)
          // Outline / Prompt / Focus mode / AI live in the side pill —
          // keeping them here too creates the "wall of icons" feel.
          ToolbarIconButton(
            iconWidget: Iconify(
              Carbon.pending,
              size: 19,
              color: textColor,
            ),
            tooltip: 'Writer Settings',
            color: textColor,
            onPressed: _showWriterSettings,
          ),
        ],
      ),
    );
  }

  // ─── Mobile bottom toolbar (formatting only) ───
  // Pinned to the bottom of the body. Image / AI / prompt / outline /
  // focus / settings live in `_buildMobileTopActions` so this row is
  // pure text formatting — comfortable to thumb while typing.
  Widget _buildMobileToolbar({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: _buildQuillToolbar(isDark: isDark, textColor: textColor),
    );
  }

  // ─── Mobile top secondary actions ───
  // Sits between the top bar and the editor. Holds the actions that
  // were previously duplicated in the side pill plus the image insert.
  Widget _buildMobileTopActions({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
  }) {
    final accentColor =
        isDark ? const Color(0xFF93B4F5) : const Color(0xFF5B8DEF);
    final mutedColor =
        isDark ? Colors.white.withValues(alpha: 0.55) : Colors.black54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      // Horizontally scrollable so the row can't overflow on narrow phones.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(
          children: [
            ToolbarIconButton(
              iconWidget: Iconify(
                Ph.google_photos_logo_bold,
                size: 19,
                color: textColor,
              ),
              tooltip: 'Insert Image',
              color: textColor,
              onPressed: _insertImage,
            ),
            ToolbarIconButton(
              icon: CupertinoIcons.sidebar_right,
              tooltip: 'Sections',
              color: textColor,
              onPressed: () => _showSectionsSheet(
                isDark: isDark,
                textColor: textColor,
                borderColor: borderColor,
              ),
            ),
            Container(
              width: 1,
              height: 20,
              margin: const EdgeInsets.symmetric(horizontal: 6),
              color: borderColor,
            ),
            ToolbarIconButton(
              icon: CupertinoIcons.wand_stars,
              tooltip: 'AI assist',
              color: accentColor,
              onPressed: _showAIPanel,
            ),
            ToolbarIconButton(
              icon: CupertinoIcons.lightbulb,
              tooltip: 'Writing prompt',
              color: Colors.amber.withValues(alpha: 0.85),
              onPressed: _showRandomPrompt,
            ),
            ToolbarIconButton(
              icon: CupertinoIcons.list_bullet_indent,
              tooltip: _showOutline ? 'Hide outline' : 'Show outline',
              color: _showOutline ? accentColor : textColor,
              onPressed: () =>
                  setState(() => _showOutline = !_showOutline),
            ),
            ToolbarIconButton(
              icon: CupertinoIcons.info,
              tooltip: 'Inspector',
              color: textColor,
              onPressed: () => _showInspectorSheet(
                isDark: isDark,
                textColor: textColor,
                borderColor: borderColor,
              ),
            ),
            ToolbarIconButton(
              icon: CupertinoIcons.eye_slash,
              tooltip: 'Focus mode',
              color: textColor,
              onPressed: _toggleFocusMode,
            ),
            _buildSyncStatusChip(mutedColor: mutedColor),
            ToolbarIconButton(
              iconWidget: Iconify(
                Carbon.pending,
                size: 19,
                color: textColor,
              ),
              tooltip: 'Writer settings',
              color: textColor,
              onPressed: _showWriterSettings,
            ),
          ],
        ),
      ),
    );
  }

  // ─── Quill Toolbar (compact, Word-style) ───
  Widget _buildQuillToolbar({required bool isDark, required Color textColor}) {
    final controller = context.read<EditorProvider>().controller;
    return WordStyleToolbar(
      controller: controller,
      isDark: isDark,
      textColor: textColor,
      onToggleFindReplace: () =>
          setState(() => _findReplaceOpen = !_findReplaceOpen),
      findReplaceOpen: _findReplaceOpen,
    );
  }

  // ─── Canvas Mode (Creative / Scrapbook) ───
  Widget _buildCanvasMode({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
  }) {
    final provider = context.watch<EditorProvider>();
    final section = provider.activeSection;
    if (section == null) {
      return Center(
        child: Text(
          'Select or create a section',
          style: GoogleFonts.inter(
            color: textColor.withValues(alpha: 0.3),
            fontSize: 15,
          ),
        ),
      );
    }

    return CanvasEditor(
      key: ValueKey('canvas_${section.id}'),
      initialData: section.canvasData,
      isDark: isDark,
      writingPreview: provider.getPreviewText(section.content),
      bookTitle: provider.activeBook?.title ?? '',
      sectionTitle: section.title,
      otherSectionTitles: provider.allBooksSection
          .where((s) => s.id != section.id)
          .map((s) => s.title)
          .toList(),
      onChanged: (data) {
        provider.saveCanvasData(data);
      },
      onUploadImage: (bytes) async {
        final auth = context.read<AuthProvider>();
        if (auth.currentUser == null) return null;
        final result = await auth.storageService.uploadEditorImage(
          auth.currentUser!.id,
          bytes,
        );
        // Canvas elements store a single URL string. `result.url` is the
        // medium variant with a `#bh=...` meta fragment — small enough for
        // a thumbnail (no 2400 px memory regression) but still rehydratable
        // back into ImageMeta if the canvas renderer ever wants the
        // blurhash placeholder.
        return result.url;
      },
    );
  }

  // ─── Outline Panel ───
  Widget _buildOutlinePanel({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
    required Color surfaceColor,
  }) {
    final headings = _extractOutline();
    final accentColor =
        isDark ? const Color(0xFF5B8DEF) : const Color(0xFF4A6CF7);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      width: 220,
      decoration: BoxDecoration(
        color: surfaceColor.withValues(alpha: 0.5),
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                Icon(CupertinoIcons.list_bullet_indent,
                    size: 14, color: accentColor),
                const SizedBox(width: 8),
                Text(
                  'Outline',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: textColor.withValues(alpha: 0.6),
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => setState(() => _showOutline = false),
                  child: Icon(CupertinoIcons.xmark,
                      size: 12, color: textColor.withValues(alpha: 0.3)),
                ),
              ],
            ),
          ),
          Divider(color: borderColor, height: 1),
          Expanded(
            child: headings.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(CupertinoIcons.text_badge_plus,
                            size: 24,
                            color: textColor.withValues(alpha: 0.15)),
                        const SizedBox(height: 8),
                        Text(
                          'Add headings (H1, H2, H3) to build your outline.',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color: textColor.withValues(alpha: 0.3),
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: headings.length,
                    itemBuilder: (ctx, idx) {
                      final h = headings[idx];
                      final indent = (h.level - 1) * 12.0;
                      return InkWell(
                        onTap: () => _jumpToOffset(h.offset),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                              16 + indent, 6, 12, 6),
                          child: Row(
                            children: [
                              Container(
                                width: 18,
                                alignment: Alignment.center,
                                child: Text(
                                  'H${h.level}',
                                  style: GoogleFonts.jetBrainsMono(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w600,
                                    color: accentColor.withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  h.text,
                                  style: GoogleFonts.inter(
                                    fontSize: h.level == 1 ? 13 : 12,
                                    fontWeight: h.level == 1
                                        ? FontWeight.w600
                                        : FontWeight.w500,
                                    color: textColor.withValues(
                                        alpha: h.level == 1 ? 0.8 : 0.55),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  // ─── Editor Area ───
  Widget _buildEditorArea({
    required bool isDark,
    required Color bgColor,
    required Color textColor,
    required bool isMobile,
  }) {
    final paperColor = _getPaperColor(isDark);
    final themedTextColor = _paperTheme == PaperTheme.defaultTheme
        ? textColor
        : _getTextColor(isDark);
    final paperBorder = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.06);

    final focusBorder = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    final showRuler = !isMobile;
    final padL = isMobile ? 18.0 : _leftMargin;
    final padR = isMobile ? 18.0 : _rightMargin;

    return Container(
      color: bgColor,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: _focusMode ? 760 : 820),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            isMobile ? 0 : (_focusMode ? 24 : 20),
            isMobile ? 0 : (_focusMode ? 24 : 12),
            isMobile ? 0 : (_focusMode ? 24 : 20),
            0,
          ),
          child: Column(
            children: [
              if (showRuler) ...[
                RulerBar(
                  isDark: isDark,
                  leftMargin: _leftMargin,
                  rightMargin: _rightMargin,
                  onChanged: _setMargins,
                ),
                const SizedBox(height: 12),
              ],
              Expanded(
                child: _buildPageCard(
                  isDark: isDark,
                  isMobile: isMobile,
                  padL: padL,
                  padR: padR,
                  paperColor: paperColor,
                  paperBorder: paperBorder,
                  focusBorder: focusBorder,
                  themedTextColor: themedTextColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageCard({
    required bool isDark,
    required bool isMobile,
    required double padL,
    required double padR,
    required Color paperColor,
    required Color paperBorder,
    required Color focusBorder,
    required Color themedTextColor,
  }) {
    return Container(
      decoration: isMobile
          ? BoxDecoration(color: paperColor)
          : _focusMode
              ? BoxDecoration(
                  color: paperColor,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(14)),
                  border: Border.all(color: focusBorder),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: isDark ? 0.45 : 0.10),
                      blurRadius: 40,
                      spreadRadius: -8,
                      offset: const Offset(0, 12),
                    ),
                  ],
                )
              : BoxDecoration(
                  color: paperColor,
                  borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(14)),
                  border: Border.all(color: paperBorder),
                  // Soft floating-paper shadow — sells the page metaphor
                  // without the high-contrast slab Material defaults to.
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                          alpha: isDark ? 0.35 : 0.08),
                      blurRadius: 32,
                      spreadRadius: -10,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
      padding: EdgeInsets.fromLTRB(
        padL,
        _focusMode ? (isMobile ? 4 : 4) : 4,
        padR,
        0,
      ),
      child: Builder(
        builder: (ctx) {
              final sectionId = ctx.select<EditorProvider, String?>(
                (p) => p.activeSection?.id,
              );
              final bottomPad = MediaQuery.of(ctx).padding.bottom +
                  MediaQuery.of(ctx).viewInsets.bottom +
                  (_typewriterMode ? MediaQuery.sizeOf(ctx).height * 0.4 : 120);
              // Typewriter mode also wants a top runway so the very first
              // line can sit near the middle of the page without bottoming
              // out the scroll view's minScrollExtent.
              final topPad = _typewriterMode
                  ? MediaQuery.sizeOf(ctx).height * 0.32
                  : 0.0;

              // Buttery selection + cursor: a soft accent (not the harsh
              // platform default), translucent selection, and matching
              // handles. Quill resolves these from the ambient
              // TextSelectionTheme, so wrapping the editor is enough.
              final accent = isDark
                  ? const Color(0xFFB4D4FF)
                  : const Color(0xFF5B8DEF);
              final selectionTint = accent.withValues(alpha: 0.22);

              final editor = QuillEditor.basic(
                key: ValueKey(sectionId ?? 'none'),
                controller: ctx.read<EditorProvider>().controller,
                focusNode: _editorFocusNode,
                scrollController: _editorScrollController,
                config: QuillEditorConfig(
                  placeholder: 'Start writing...',
                  editorKey: _editorStateKey,
                  // BouncingScrollPhysics + AlwaysScrollableScrollPhysics
                  // gives the iOS-style rubber-band on every platform —
                  // small thing, but the soft overscroll bounce sells
                  // the "page is alive under your finger" feel.
                  scrollPhysics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  textSelectionThemeData: TextSelectionThemeData(
                    cursorColor: accent,
                    selectionColor: selectionTint,
                    selectionHandleColor: accent,
                  ),
                  embedBuilders: [
                    ImageEmbedBuilder(
                      controller: ctx.read<EditorProvider>().controller,
                    ),
                  ],
                  padding: EdgeInsets.only(top: topPad, bottom: bottomPad),
                  customStyleBuilder: _customStyleBuilder,
                  customStyles: DefaultStyles(
                    placeHolder: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: _focusMode ? 18 : 17,
                        color: themedTextColor.withValues(alpha: 0.22),
                        height: 1.7,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(0, 0),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    paragraph: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: _focusMode ? 18 : 17,
                        height: _focusMode ? 1.9 : 1.7,
                        color: themedTextColor.withValues(alpha: 0.9),
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(10, 0),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    h1: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                        color: themedTextColor,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(20, 10),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    h2: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                        color: themedTextColor,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(16, 8),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    h3: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                        color: themedTextColor,
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(14, 6),
                      const VerticalSpacing(0, 0),
                      null,
                    ),
                    quote: DefaultTextBlockStyle(
                      GoogleFonts.inter(
                        fontSize: 17,
                        fontStyle: FontStyle.italic,
                        height: 1.6,
                        color: themedTextColor.withValues(alpha: 0.7),
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(10, 10),
                      const VerticalSpacing(0, 0),
                      BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: themedTextColor.withValues(alpha: 0.2),
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                    code: DefaultTextBlockStyle(
                      GoogleFonts.jetBrainsMono(
                        fontSize: 14,
                        height: 1.5,
                        color: themedTextColor.withValues(alpha: 0.85),
                      ),
                      const HorizontalSpacing(0, 0),
                      const VerticalSpacing(8, 8),
                      const VerticalSpacing(0, 0),
                      BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : Colors.black.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              );

              if (_aiPanel == null) return editor;

              final panel = _aiPanel!;
              final mutedColor = isDark
                  ? Colors.white.withValues(alpha: 0.45)
                  : Colors.black.withValues(alpha: 0.45);
              final surfaceColor = isDark
                  ? const Color(0xFF141414)
                  : const Color(0xFFF5F5F7);

              // Render the panel directly on the editor canvas — same paper
              // background, same horizontal padding as the QuillEditor, so
              // the diff appears to live inside the document instead of on
              // top of it.
              return AIAssistPanel(
                gemini: _gemini,
                action: panel.action,
                sourceDelta: panel.sourceDelta,
                plainText: panel.plainText,
                hasSelection: panel.hasSelection,
                isDark: isDark,
                textColor: themedTextColor,
                mutedColor: mutedColor,
                surfaceColor: surfaceColor,
                backgroundColor: paperColor,
                focusMode: _focusMode,
                // Horizontal & top padding come from the page card around
                // this widget; only add internal vertical breathing room.
                contentPadding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                onApply: (mergedJson) {
                  _applyMergedDelta(
                    ctx.read<EditorProvider>().controller,
                    mergedJson,
                    panel.replaceIndex,
                    panel.replaceLength,
                    stripTrailingNewline: !panel.sourceEndsWithNewline,
                  );
                },
                onClose: _closeAIPanel,
              );
            },
          ),
        );
  }

  /// Handles Google Fonts rendering for the `font` attribute.
  /// Resolved styles are cached: GoogleFonts.getFont does internal work
  /// (font asset lookup, descriptor parsing) that's not free, and Quill
  /// invokes this builder per styled-span on every paint of the editor.
  TextStyle _customStyleBuilder(Attribute attr) {
    if (attr.key == 'font') {
      final name = attr.value as String?;
      if (name != null && name.isNotEmpty && name != 'Clear') {
        return cachedFontStyle(name);
      }
    }
    if (attr.key == 'size') {
      final raw = attr.value;
      final size = raw is num
          ? raw.toDouble()
          : double.tryParse(raw?.toString() ?? '');
      if (size != null && size > 0) {
        return TextStyle(fontSize: size);
      }
    }
    if (attr.key == kSpellCheckErrorKey && attr.value == true) {
      return kSpellCheckErrorStyle;
    }
    return const TextStyle();
  }

  // ─── Sidebar ───
  Widget _buildSidebar({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
    required Color surfaceColor,
  }) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      width: context.select<EditorProvider, bool>((p) => p.showSectionsList)
          ? 260
          : 0,
      decoration: BoxDecoration(
        color: surfaceColor.withValues(alpha: 0.5),
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: ClipRect(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          child: SizedBox(
            width: 260,
            child: const BinderPane(),
          ),
        ),
      ),
    );
  }

  // ─── Enhanced Status Bar ───
  Widget _buildStatusBar({
    required Color bgColor,
    required Color textColor,
    required Color borderColor,
    required Color mutedColor,
    required bool isDark,
  }) {
    final isMobile = Breakpoints.isMobile(MediaQuery.sizeOf(context).width);

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      // Word/char counts. We listen to the QuillController directly so
      // typing updates the counters live without rebuilding the rest of
      // the editor through EditorProvider's broadcast.
      // Selector picks up section switches (which replace the controller)
      // and ListenableBuilder rebuilds locally on document edits.
      child: Selector<EditorProvider, QuillController>(
        selector: (_, p) => p.controller,
        builder: (context, controller, _) => ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
          final text = controller.document.toPlainText().trim();
          final wordCount =
              text.isEmpty ? 0 : text.split(RegExp(r'\s+')).length;
          final charCount = text.length;
          final readTime = (wordCount / 200).ceil();
          final sessionWords = wordCount - _sessionStartWords;

          final style = GoogleFonts.inter(
            fontSize: 11,
            color: textColor.withValues(alpha: 0.3),
          );

          // Use a compact dot separator instead of wide dividers
          Widget dot() => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('\u00b7',
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        color: textColor.withValues(alpha: 0.15))),
              );

          // Build stat items — fewer on mobile
          final stats = <Widget>[
            Text('$wordCount words', style: style),
            dot(),
            Text('$charCount chars', style: style),
            if (!isMobile) ...[
              dot(),
              Text(
                  '${readTime < 1 ? '<1' : readTime} min read', style: style),
            ],
          ];

          // Session indicator on the right
          Widget? sessionWidget;
          if (sessionWords > 0) {
            sessionWidget = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.arrow_up_right,
                    size: 10,
                    color: Colors.green.withValues(alpha: 0.6)),
                const SizedBox(width: 3),
                Text(
                  '+$sessionWords session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.green.withValues(alpha: 0.5),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            );
          } else if (sessionWords < 0) {
            sessionWidget = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(CupertinoIcons.arrow_down_right,
                    size: 10,
                    color: Colors.orange.withValues(alpha: 0.5)),
                const SizedBox(width: 3),
                Text(
                  '$sessionWords session',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Colors.orange.withValues(alpha: 0.5),
                  ),
                ),
              ],
            );
          }

          return Row(
            children: [
              // Left: scrollable stats so they never overflow
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: stats,
                  ),
                ),
              ),
              // Right: spell-check chip + session + optional mode badge
              Consumer<SpellCheckProvider>(
                builder: (_, sp, _) {
                  if (!sp.enabled) return const SizedBox.shrink();
                  final issues = sp.issues.length;
                  // Until the first scan resolves we don't actually know
                  // whether there are issues — show a neutral "Checking…"
                  // chip rather than a misleading green "No issues".
                  final pending = !sp.hasScanned;
                  final Color color;
                  final IconData icon;
                  final String label;
                  if (pending) {
                    color = Colors.white.withValues(alpha: 0.45);
                    icon = CupertinoIcons.arrow_2_circlepath;
                    label = 'Checking…';
                  } else if (issues == 0) {
                    color = Colors.green.withValues(alpha: 0.55);
                    icon = CupertinoIcons.checkmark_seal;
                    label = 'No issues';
                  } else {
                    color = const Color(0xFFE26A4A).withValues(alpha: 0.85);
                    icon = CupertinoIcons.exclamationmark_circle;
                    label = '$issues issue${issues == 1 ? '' : 's'}';
                  }
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: issues == 0 ? null : _showSpellCheckSheet,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(icon, size: 11, color: color),
                          const SizedBox(width: 4),
                          Text(
                            label,
                            style: GoogleFonts.inter(
                              fontSize: 11,
                              color: color,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (sessionWidget != null || _typewriterMode) ...[
                if (_typewriterMode) ...[
                  Icon(CupertinoIcons.text_cursor,
                      size: 10, color: mutedColor),
                  const SizedBox(width: 4),
                ],
                if (sessionWidget != null) sessionWidget,
              ],
            ],
          );
          },
        ),
      ),
    );
  }

  // ─── Writing Prompt Overlay ───
  Widget _buildPromptOverlay({
    required bool isDark,
    required Color textColor,
    required bool isMobile,
  }) {
    return Positioned(
      bottom: isMobile ? 50 : 40,
      left: isMobile ? 16 : null,
      right: isMobile ? 16 : 20,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        builder: (context, value, child) => Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: Opacity(opacity: value, child: child),
        ),
        child: Container(
          constraints: BoxConstraints(maxWidth: isMobile ? double.infinity : 400),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1A1A2E) : const Color(0xFFFFF8E1),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isDark
                  ? Colors.amber.withValues(alpha: 0.15)
                  : Colors.amber.withValues(alpha: 0.3),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.1),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(CupertinoIcons.lightbulb_fill,
                      size: 14, color: Colors.amber),
                  const SizedBox(width: 8),
                  Text(
                    'Writing Prompt',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.amber.withValues(alpha: 0.8),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _showRandomPrompt,
                    child: Icon(CupertinoIcons.arrow_2_circlepath,
                        size: 14, color: textColor.withValues(alpha: 0.4)),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _activePrompt = null),
                    child: Icon(CupertinoIcons.xmark,
                        size: 13, color: textColor.withValues(alpha: 0.3)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _activePrompt ?? '',
                style: GoogleFonts.merriweather(
                  fontSize: 14,
                  height: 1.6,
                  fontStyle: FontStyle.italic,
                  color: isDark
                      ? const Color(0xFFE0D5BA)
                      : const Color(0xFF5D4E37),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── Daily Goal Widget ───
  Widget _buildGoalWidget({
    required bool isDark,
    required Color textColor,
    required bool isMobile,
  }) {
    return Positioned(
      top: isMobile ? 56 : 100,
      right: isMobile ? 8 : 20,
      // Live word count via direct controller listening (see status bar
      // for the same pattern). Avoids per-keystroke EditorProvider rebuild.
      // The progress numbers come straight from this State's fields —
      // word tracking is handled by the always-on controller listener
      // wired up in didChangeDependencies, so we don't need to read
      // the controller here at all. This builder simply re-renders
      // when setState fires from _onWordCountTick.
      child: Builder(
        builder: (context) {
          final progress =
              (_dailyWordsToday / _dailyGoal).clamp(0.0, 1.0);
          final isComplete = progress >= 1.0;

          return Container(
            width: isMobile ? 56 : 160,
            padding: EdgeInsets.all(isMobile ? 8 : 12),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF141414).withValues(alpha: 0.95)
                  : Colors.white.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isComplete
                    ? Colors.green.withValues(alpha: 0.3)
                    : (isDark
                        ? Colors.white.withValues(alpha: 0.06)
                        : Colors.black.withValues(alpha: 0.06)),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: isMobile
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 3,
                              backgroundColor: isDark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.black.withValues(alpha: 0.06),
                              valueColor: AlwaysStoppedAnimation(
                                isComplete
                                    ? Colors.green
                                    : const Color(0xFF5B8DEF),
                              ),
                            ),
                            Center(
                              child: isComplete
                                  ? Icon(CupertinoIcons.checkmark,
                                      size: 14, color: Colors.green)
                                  : Text(
                                      '${(progress * 100).toInt()}',
                                      style: GoogleFonts.inter(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: textColor,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            isComplete
                                ? CupertinoIcons.checkmark_seal_fill
                                : CupertinoIcons.flame,
                            size: 14,
                            color: isComplete ? Colors.green : Colors.orange,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              isComplete
                                  ? 'Goal reached!'
                                  : 'Daily Goal',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: isComplete
                                    ? Colors.green
                                    : textColor.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                          if (_streak > 0) ...[
                            Icon(CupertinoIcons.flame_fill,
                                size: 11, color: Colors.orange),
                            const SizedBox(width: 2),
                            Text(
                              '$_streak',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Colors.orange,
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          GestureDetector(
                            onTap: () {
                              setState(() => _showGoalWidget = false);
                              _persistGoalSetting();
                            },
                            child: Icon(CupertinoIcons.xmark,
                                size: 10,
                                color: textColor.withValues(alpha: 0.2)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 4,
                          backgroundColor: isDark
                              ? Colors.white.withValues(alpha: 0.06)
                              : Colors.black.withValues(alpha: 0.06),
                          valueColor: AlwaysStoppedAnimation(
                            isComplete
                                ? Colors.green
                                : const Color(0xFF5B8DEF),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '$_dailyWordsToday / $_dailyGoal words',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: textColor.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
  }

  // ─── Helpers ───

  void _promptNewSection() {
    final provider = context.read<EditorProvider>();
    _showTextInputDialog(
      title: 'New Section',
      initialValue: 'Section ${provider.allBooksSection.length + 1}',
      onSave: (val) => provider.addSection(val, autoSelect: true),
    );
  }

  void _showFailedOpsSheet(BuildContext context, EditorProvider provider) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final muted = textColor.withValues(alpha: 0.6);
    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return _escapeDismiss(
          ctx,
          SafeArea(
          child: AnimatedBuilder(
            animation: provider,
            builder: (ctx, _) {
              final ops = provider.failedOps;
              if (ops.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No failed operations.',
                    style: GoogleFonts.inter(color: muted),
                  ),
                );
              }
              return ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                itemCount: ops.length,
                separatorBuilder: (_, __) => Divider(
                  color: textColor.withValues(alpha: 0.08),
                  height: 24,
                ),
                itemBuilder: (ctx, i) {
                  final op = ops[i];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              op.kind.name,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              op.lastError ?? 'unknown error',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: muted,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${op.attemptCount} attempts',
                              style: GoogleFonts.inter(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        onPressed: () => provider.retryFailedOp(op.id),
                        child: const Text('Retry'),
                      ),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        onPressed: () => provider.discardFailedOp(op.id),
                        child: Text(
                          'Discard',
                          style: TextStyle(
                              color: Colors.red.withValues(alpha: 0.85)),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          ),
        );
      },
    );
  }

  void _showSectionsSheet({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
  }) {
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;

    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _escapeDismiss(
        ctx,
        DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.85,
        expand: false,
        builder: (_, scrollCtrl) => Column(
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: textColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  Text(
                    'Sections',
                    style: GoogleFonts.inter(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: Icon(CupertinoIcons.xmark,
                        size: 18, color: textColor),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),
            Expanded(
              child: BinderPane(
                onItemTap: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  void _showInspectorSheet({
    required bool isDark,
    required Color textColor,
    required Color borderColor,
  }) {
    final sheetBg = isDark ? const Color(0xFF0C0C0C) : Colors.white;
    final surfaceColor = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.02);
    showModalBottomSheet(
      context: context,
      backgroundColor: sheetBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _escapeDismiss(
        ctx,
        Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(ctx).bottom,
          ),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.78,
            child: SectionInspector(
              isDark: isDark,
              textColor: textColor,
              borderColor: borderColor,
              surfaceColor: surfaceColor,
              asSheet: true,
              onClose: () => Navigator.pop(ctx),
            ),
          ),
        ),
      ),
    );
  }

  void _showTextInputDialog({
    required String title,
    required String initialValue,
    required Function(String) onSave,
  }) {
    final ctrl = TextEditingController(text: initialValue);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    showCupertinoDialog(
      context: context,
      builder: (ctx) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(ctx).pop(),
        },
        child: CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: ctrl,
            autofocus: true,
            placeholder: 'Enter name...',
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(10),
            ),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) onSave(v.trim());
              Navigator.pop(ctx);
            },
          ),
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: false,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) onSave(ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
      ),
    );
  }
}
