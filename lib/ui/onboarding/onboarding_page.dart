import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/preference_options.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage>
    with TickerProviderStateMixin {
  final PageController _pageController = PageController();
  int _currentPage = 0;
  bool _isFinishing = false;
  bool _isCtaHovered = false;

  // ── Collected preferences ──
  String? _primaryRole;
  String? _experienceLevel;
  final List<String> _goals = [];
  final List<String> _selectedWritingTypes = [];
  final List<String> _selectedSubtypes = [];
  final List<String> _moodThemes = [];
  String? _writingFrequency;
  String? _contentLength;

  late AnimationController _fadeController;
  late AnimationController _slideController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim;

  static const _introPages = [
    _OnboardingData(
      asset: 'assets/svg/onboarding_write.svg',
      title: 'Write Anywhere',
      subtitle: 'Your thoughts deserve a beautiful home.',
      description:
          'A distraction-free editor that adapts to your flow. Write novels, poetry, scripts, or journals \u2014 all in one place.',
    ),
    _OnboardingData(
      asset: 'assets/svg/onboarding_organize.svg',
      title: 'Organize Ideas',
      subtitle: 'Structure brings clarity.',
      description:
          'Create spaces for each project. Add chapters, sections, and notes. Everything stays organized and accessible.',
    ),
    _OnboardingData(
      asset: 'assets/svg/onboarding_share.svg',
      title: 'Share with the World',
      subtitle: 'From draft to published, seamlessly.',
      description:
          'Publish your best work to the community. Get readers, feedback, and build your audience as a writer.',
    ),
  ];

  // ── Preference step definitions (shared with feed_preferences_page) ──
  static const _roles = kRoleOptions;
  static const _experienceLevels = kExperienceOptions;
  static const _goalOptions = kGoalOptions;
  static const _moodOptions = kMoodOptions;
  static const _frequencyOptions = kFrequencyOptions;
  static const _lengthOptions = kLengthOptions;

  // Total preference steps (role+exp, goals, craft, mood+length)
  static const int _prefStepCount = 4;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _slideController,
      curve: Curves.easeOutCubic,
    ));
    _fadeController.forward();
    _slideController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  int get _totalPages => _introPages.length + _prefStepCount;
  int get _firstPrefIndex => _introPages.length;
  int get _lastPrefIndex => _totalPages - 1;
  bool get _onPrefStep => _currentPage >= _firstPrefIndex;
  bool get _onFinalStep => _currentPage == _lastPrefIndex;

  void _onPageChanged(int index) {
    setState(() => _currentPage = index);
    _fadeController.reset();
    _slideController.reset();
    _fadeController.forward();
    _slideController.forward();
  }

  void _nextPage() {
    if (_currentPage < _totalPages - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOutCubic,
      );
    } else {
      _finishOnboarding();
    }
  }

  void _skip() {
    _pageController.animateToPage(
      _firstPrefIndex,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _finishOnboarding() async {
    if (_isFinishing) return;
    final auth = context.read<AuthProvider>();
    setState(() => _isFinishing = true);
    try {
      final prefs = UserPreferences(
        preferredGenres: _selectedSubtypes,
        preferredWritingTypes: _selectedWritingTypes,
        interests: const [],
        primaryRole: _primaryRole,
        experienceLevel: _experienceLevel,
        goals: _goals,
        moodThemes: _moodThemes,
        writingFrequency: _writingFrequency,
        contentLengthPreference: _contentLength,
      );
      await auth.completeOnboarding(prefs).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw Exception(
          'Request timed out. Please check your connection and try again.',
        ),
      );
    } catch (e, st) {
      debugPrint('[Onboarding] completeOnboarding failed: $e\n$st');
      if (!mounted) return;
      setState(() => _isFinishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Couldn\'t save your preferences: ${e.toString().replaceFirst('Exception: ', '')}',
            style: GoogleFonts.inter(fontSize: 13.5),
          ),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  bool get _canAdvance {
    if (!_onPrefStep) return true;
    final step = _currentPage - _firstPrefIndex;
    switch (step) {
      case 0:
        return _primaryRole != null && _experienceLevel != null;
      case 1:
        return _goals.isNotEmpty;
      case 2:
        return _selectedWritingTypes.isNotEmpty ||
            _selectedSubtypes.isNotEmpty;
      case 3:
        return _moodThemes.isNotEmpty &&
            _writingFrequency != null &&
            _contentLength != null;
      default:
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0A0A0B) : const Color(0xFFFAFAFB);
    final textColor = isDark ? Colors.white : const Color(0xFF111111);
    final mutedColor = isDark
        ? Colors.white.withValues(alpha: 0.50)
        : Colors.black.withValues(alpha: 0.50);

    return Scaffold(
      backgroundColor: bgColor,
      body: Stack(
        children: [
          // ── Ambient background glow ──
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.6, -0.7),
                    radius: 1.1,
                    colors: isDark
                        ? [
                            const Color(0xFF6B5CFF).withValues(alpha: 0.09),
                            Colors.transparent,
                          ]
                        : [
                            const Color(0xFF6B5CFF).withValues(alpha: 0.05),
                            Colors.transparent,
                          ],
                  ),
                ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.8, 0.9),
                    radius: 0.9,
                    colors: isDark
                        ? [
                            const Color(0xFFFF7A59).withValues(alpha: 0.06),
                            Colors.transparent,
                          ]
                        : [
                            const Color(0xFFFF7A59).withValues(alpha: 0.04),
                            Colors.transparent,
                          ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                // ── Top bar ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: List.generate(_totalPages, (i) {
                          final isActive = i == _currentPage;
                          final isPast = i < _currentPage;
                          return AnimatedContainer(
                            duration: const Duration(milliseconds: 350),
                            curve: Curves.easeOutCubic,
                            margin: const EdgeInsets.only(right: 6),
                            height: 3,
                            width: isActive ? 24 : 10,
                            decoration: BoxDecoration(
                              color: isActive
                                  ? textColor.withValues(alpha: 0.9)
                                  : isPast
                                      ? textColor.withValues(alpha: 0.35)
                                      : textColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        }),
                      ),
                      if (!_onPrefStep)
                        GestureDetector(
                          onTap: _skip,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 4),
                            child: Text(
                              'Skip',
                              style: GoogleFonts.inter(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: mutedColor,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        )
                      else
                        Text(
                          _onFinalStep
                              ? 'Almost there'
                              : 'Step ${_currentPage - _firstPrefIndex + 1} of $_prefStepCount',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: mutedColor,
                          ),
                        ),
                    ],
                  ),
                ),

                // ── Page content ──
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: _totalPages,
                    onPageChanged: _onPageChanged,
                    physics: const ClampingScrollPhysics(),
                    itemBuilder: (context, index) {
                      if (index < _introPages.length) {
                        return _buildIntroPage(
                          _introPages[index],
                          isDark,
                          textColor,
                          mutedColor,
                        );
                      }
                      final step = index - _firstPrefIndex;
                      return _buildPrefStep(
                          step, isDark, textColor, mutedColor);
                    },
                  ),
                ),

                // ── Bottom CTA ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: MouseRegion(
                        cursor: _canAdvance
                            ? SystemMouseCursors.click
                            : SystemMouseCursors.basic,
                        onEnter: (_) {
                          if (!_isFinishing && _canAdvance) {
                            setState(() => _isCtaHovered = true);
                          }
                        },
                        onExit: (_) {
                          if (_isCtaHovered) {
                            setState(() => _isCtaHovered = false);
                          }
                        },
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 220),
                          opacity: _canAdvance ? 1.0 : 0.4,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            height: 54,
                            width: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(27),
                              color: textColor,
                              boxShadow: [
                                BoxShadow(
                                  color: textColor.withValues(
                                      alpha: _isCtaHovered ? 0.14 : 0.06),
                                  blurRadius: _isCtaHovered ? 22 : 12,
                                  offset: Offset(0, _isCtaHovered ? 6 : 3),
                                ),
                              ],
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(27),
                                onTap: (_isFinishing || !_canAdvance)
                                    ? null
                                    : _nextPage,
                                child: Center(
                                  child: _isFinishing
                                      ? CupertinoActivityIndicator(
                                          color: bgColor,
                                          radius: 10,
                                        )
                                      : Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              _onFinalStep
                                                  ? 'Get Started'
                                                  : 'Continue',
                                              style: GoogleFonts.inter(
                                                fontSize: 15.5,
                                                fontWeight: FontWeight.w600,
                                                color: bgColor,
                                                letterSpacing: 0.2,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            AnimatedSlide(
                                              duration: const Duration(
                                                  milliseconds: 200),
                                              curve: Curves.easeOut,
                                              offset: _isCtaHovered
                                                  ? const Offset(0.15, 0)
                                                  : Offset.zero,
                                              child: Icon(
                                                CupertinoIcons.arrow_right,
                                                size: 16,
                                                color: bgColor,
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────
  // Intro page
  // ─────────────────────────────────────────────────
  Widget _buildIntroPage(
    _OnboardingData data,
    bool isDark,
    Color textColor,
    Color mutedColor,
  ) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(flex: 3),
                  SizedBox(
                    height: 200,
                    width: 200,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: [
                                textColor.withValues(alpha: 0.06),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                        Container(
                          width: 170,
                          height: 170,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: textColor.withValues(alpha: 0.06),
                              width: 1,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 110,
                          width: 110,
                          child: isDark
                              ? SvgPicture.asset(data.asset)
                              : ColorFiltered(
                                  colorFilter: const ColorFilter.matrix([
                                    -1, 0, 0, 0, 255, //
                                    0, -1, 0, 0, 255, //
                                    0, 0, -1, 0, 255, //
                                    0, 0, 0, 1, 0, //
                                  ]),
                                  child: SvgPicture.asset(data.asset),
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 56),
                  Text(
                    data.title,
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 38,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                      height: 1.15,
                      letterSpacing: -0.8,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    data.subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: textColor.withValues(alpha: 0.72),
                      height: 1.4,
                      letterSpacing: 0.1,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    height: 1,
                    width: 40,
                    color: textColor.withValues(alpha: 0.12),
                  ),
                  const SizedBox(height: 20),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 380),
                    child: Text(
                      data.description,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: mutedColor,
                        height: 1.65,
                        letterSpacing: 0.1,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const Spacer(flex: 4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────
  // Preference steps router
  // ─────────────────────────────────────────────────
  Widget _buildPrefStep(
    int step,
    bool isDark,
    Color textColor,
    Color mutedColor,
  ) {
    switch (step) {
      case 0:
        return _buildRoleStep(isDark, textColor, mutedColor);
      case 1:
        return _buildGoalsStep(isDark, textColor, mutedColor);
      case 2:
        return _buildCraftStep(isDark, textColor, mutedColor);
      case 3:
        return _buildTasteStep(isDark, textColor, mutedColor);
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _stepScaffold({
    required String eyebrow,
    required String title,
    required String subtitle,
    required Color textColor,
    required Color mutedColor,
    required Widget child,
  }) {
    return FadeTransition(
      opacity: _fadeAnim,
      child: SlideTransition(
        position: _slideAnim,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(28, 16, 28, 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  _Eyebrow(text: eyebrow, mutedColor: mutedColor),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      height: 1.15,
                      letterSpacing: -0.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 15,
                      color: mutedColor,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 28),
                  child,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Step 1 — Role + Experience
  Widget _buildRoleStep(bool isDark, Color textColor, Color mutedColor) {
    return _stepScaffold(
      eyebrow: 'ABOUT YOU',
      title: 'What brings you to\nInkSpace?',
      subtitle:
          "We'll shape the experience around how you plan to use the app.",
      textColor: textColor,
      mutedColor: mutedColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: _roles.map((r) {
              final selected = _primaryRole == r.value;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    right: r == _roles.last ? 0 : 10,
                  ),
                  child: _BigCard(
                    selected: selected,
                    isDark: isDark,
                    textColor: textColor,
                    mutedColor: mutedColor,
                    icon: r.icon!,
                    label: r.label,
                    description: r.description,
                    onTap: () => setState(() => _primaryRole = r.value),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
          _SectionLabel(text: 'EXPERIENCE LEVEL', mutedColor: mutedColor),
          const SizedBox(height: 14),
          ..._experienceLevels.map((exp) {
            final selected = _experienceLevel == exp.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _RowCard(
                selected: selected,
                isDark: isDark,
                textColor: textColor,
                mutedColor: mutedColor,
                icon: exp.icon!,
                label: exp.label,
                description: exp.description,
                onTap: () => setState(() => _experienceLevel = exp.value),
              ),
            );
          }),
        ],
      ),
    );
  }

  // Step 2 — Goals
  Widget _buildGoalsStep(bool isDark, Color textColor, Color mutedColor) {
    return _stepScaffold(
      eyebrow: 'YOUR GOALS',
      title: 'What do you hope\nto get from this?',
      subtitle: 'Pick anything that resonates — you can change this later.',
      textColor: textColor,
      mutedColor: mutedColor,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: _goalOptions.map((g) {
          final selected = _goals.contains(g.value);
          return _PillChip(
            label: g.label,
            icon: g.icon,
            selected: selected,
            isDark: isDark,
            textColor: textColor,
            onTap: () => setState(() {
              selected ? _goals.remove(g.value) : _goals.add(g.value);
            }),
          );
        }).toList(),
      ),
    );
  }

  // Step 3 — Writing types & formats
  Widget _buildCraftStep(bool isDark, Color textColor, Color mutedColor) {
    return _stepScaffold(
      eyebrow: 'YOUR CRAFT',
      title: 'What do you love\nto write or read?',
      subtitle:
          'Select the styles and formats that draw you in. We\'ll use this to curate your feed.',
      textColor: textColor,
      mutedColor: mutedColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(text: 'WRITING TYPES', mutedColor: mutedColor),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: WritingType.values.map((wt) {
              final key = wt.name;
              final selected = _selectedWritingTypes.contains(key);
              return _PillChip(
                label: wt.displayName,
                selected: selected,
                isDark: isDark,
                textColor: textColor,
                onTap: () => setState(() {
                  selected
                      ? _selectedWritingTypes.remove(key)
                      : _selectedWritingTypes.add(key);
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 28),
          _SectionLabel(text: 'FORMATS', mutedColor: mutedColor),
          const SizedBox(height: 4),
          ...WritingType.values.map((wt) {
            final subtypes = getDisplaySubtypesForWritingType(wt);
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      wt.displayName,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: textColor.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: subtypes.map((label) {
                      final selected = _selectedSubtypes.contains(label);
                      return _PillChip(
                        label: label,
                        selected: selected,
                        isDark: isDark,
                        textColor: textColor,
                        onTap: () => setState(() {
                          selected
                              ? _selectedSubtypes.remove(label)
                              : _selectedSubtypes.add(label);
                        }),
                      );
                    }).toList(),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // Step 4 — Mood + rhythm + length
  Widget _buildTasteStep(bool isDark, Color textColor, Color mutedColor) {
    return _stepScaffold(
      eyebrow: 'YOUR TASTE',
      title: 'Set the mood\nand the rhythm.',
      subtitle:
          'A few last touches so the feed feels right from day one.',
      textColor: textColor,
      mutedColor: mutedColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel(text: 'VIBE', mutedColor: mutedColor),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _moodOptions.map((m) {
              final selected = _moodThemes.contains(m.value);
              return _PillChip(
                label: m.label,
                icon: m.icon,
                selected: selected,
                isDark: isDark,
                textColor: textColor,
                onTap: () => setState(() {
                  selected
                      ? _moodThemes.remove(m.value)
                      : _moodThemes.add(m.value);
                }),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
          _SectionLabel(text: 'HOW OFTEN DO YOU WRITE?', mutedColor: mutedColor),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _frequencyOptions.map((f) {
              final selected = _writingFrequency == f.value;
              return _SegmentCard(
                label: f.label,
                description: f.description,
                selected: selected,
                isDark: isDark,
                textColor: textColor,
                mutedColor: mutedColor,
                onTap: () => setState(() => _writingFrequency = f.value),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
          _SectionLabel(text: 'PREFERRED READING LENGTH', mutedColor: mutedColor),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: _lengthOptions.map((l) {
              final selected = _contentLength == l.value;
              return _SegmentCard(
                label: l.label,
                description: l.description,
                selected: selected,
                isDark: isDark,
                textColor: textColor,
                mutedColor: mutedColor,
                onTap: () => setState(() => _contentLength = l.value),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Visual primitives
// ─────────────────────────────────────────────────

class _Eyebrow extends StatelessWidget {
  final String text;
  final Color mutedColor;
  const _Eyebrow({required this.text, required this.mutedColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: mutedColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: mutedColor.withValues(alpha: 0.12),
          width: 0.8,
        ),
      ),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: mutedColor,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  final Color mutedColor;
  const _SectionLabel({required this.text, required this.mutedColor});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: GoogleFonts.inter(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: mutedColor,
        letterSpacing: 1.3,
      ),
    );
  }
}

class _PillChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool selected;
  final bool isDark;
  final Color textColor;
  final VoidCallback onTap;

  const _PillChip({
    required this.label,
    required this.selected,
    required this.isDark,
    required this.textColor,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final chipBg = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.03);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.08);
    final selectedBg = isDark ? Colors.white : textColor;
    final selectedFg = isDark ? Colors.black : Colors.white;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.symmetric(
          horizontal: icon != null ? 14 : 16,
          vertical: 11,
        ),
        decoration: BoxDecoration(
          color: selected ? selectedBg : chipBg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected ? Colors.transparent : borderColor,
            width: 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: selectedBg.withValues(alpha: isDark ? 0.15 : 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, 3),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 15,
                color: selected
                    ? selectedFg
                    : textColor.withValues(alpha: 0.65),
              ),
              const SizedBox(width: 7),
            ],
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? selectedFg
                    : textColor.withValues(alpha: 0.78),
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BigCard extends StatelessWidget {
  final bool selected;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final IconData icon;
  final String label;
  final String? description;
  final VoidCallback onTap;

  const _BigCard({
    required this.selected,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.02);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
        decoration: BoxDecoration(
          color: selected ? textColor.withValues(alpha: isDark ? 0.95 : 1) : bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: selected ? Colors.transparent : border,
            width: 1,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: textColor.withValues(alpha: 0.14),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 22,
              color: selected
                  ? (isDark ? Colors.black : Colors.white)
                  : textColor.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: selected
                    ? (isDark ? Colors.black : Colors.white)
                    : textColor,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  color: selected
                      ? (isDark
                          ? Colors.black.withValues(alpha: 0.65)
                          : Colors.white.withValues(alpha: 0.75))
                      : mutedColor,
                  height: 1.3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  final bool selected;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final IconData icon;
  final String label;
  final String? description;
  final VoidCallback onTap;

  const _RowCard({
    required this.selected,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.icon,
    required this.label,
    required this.onTap,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.02);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? textColor.withValues(alpha: isDark ? 0.95 : 1) : bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Colors.transparent : border,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? (isDark
                        ? Colors.black.withValues(alpha: 0.12)
                        : Colors.white.withValues(alpha: 0.2))
                    : textColor.withValues(alpha: 0.06),
              ),
              child: Icon(
                icon,
                size: 17,
                color: selected
                    ? (isDark ? Colors.black : Colors.white)
                    : textColor.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.inter(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? (isDark ? Colors.black : Colors.white)
                          : textColor,
                    ),
                  ),
                  if (description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      description!,
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        color: selected
                            ? (isDark
                                ? Colors.black.withValues(alpha: 0.65)
                                : Colors.white.withValues(alpha: 0.75))
                            : mutedColor,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected
                    ? (isDark ? Colors.black : Colors.white)
                    : Colors.transparent,
                border: Border.all(
                  color: selected
                      ? Colors.transparent
                      : textColor.withValues(alpha: 0.25),
                  width: 1.3,
                ),
              ),
              child: selected
                  ? Icon(
                      CupertinoIcons.checkmark_alt,
                      size: 13,
                      color: isDark ? Colors.white : textColor,
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _SegmentCard extends StatelessWidget {
  final String label;
  final String? description;
  final bool selected;
  final bool isDark;
  final Color textColor;
  final Color mutedColor;
  final VoidCallback onTap;

  const _SegmentCard({
    required this.label,
    required this.selected,
    required this.isDark,
    required this.textColor,
    required this.mutedColor,
    required this.onTap,
    this.description,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark
        ? Colors.white.withValues(alpha: 0.04)
        : Colors.black.withValues(alpha: 0.02);
    final border = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.08);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: 180,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? textColor.withValues(alpha: isDark ? 0.95 : 1) : bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? Colors.transparent : border,
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: selected
                    ? (isDark ? Colors.black : Colors.white)
                    : textColor,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 4),
              Text(
                description!,
                style: GoogleFonts.inter(
                  fontSize: 12,
                  color: selected
                      ? (isDark
                          ? Colors.black.withValues(alpha: 0.65)
                          : Colors.white.withValues(alpha: 0.75))
                      : mutedColor,
                  height: 1.3,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Data holders
// ─────────────────────────────────────────────────

class _OnboardingData {
  final String asset;
  final String title;
  final String subtitle;
  final String description;

  const _OnboardingData({
    required this.asset,
    required this.title,
    required this.subtitle,
    required this.description,
  });
}

