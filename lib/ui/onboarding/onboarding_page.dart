import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/provider/auth_provider.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final PageController _pageController = PageController();
  int _currentPage = 0;

  final List<String> _selectedWritingTypes = [];
  final List<String> _selectedSubtypes = [];

  final List<OnboardingItem> _pages = [
    OnboardingItem(
      title: "Write Anywhere",
      description: "Capture your thoughts anytime, anywhere, with ease.",
      icon: CupertinoIcons.pencil_outline,
    ),
    OnboardingItem(
      title: "Organize Ideas",
      description: "Keep your writings structured and easily accessible.",
      icon: CupertinoIcons.folder_open,
    ),
    OnboardingItem(
      title: "Share with World",
      description:
          "Publish your best work and get feedback from the community.",
      icon: CupertinoIcons.share_up,
    ),
  ];

  void _finishOnboarding() async {
    final prefs = UserPreferences(
      preferredGenres: _selectedSubtypes,
      preferredWritingTypes: _selectedWritingTypes,
      interests: [],
    );
    await context.read<AuthProvider>().completeOnboarding(prefs);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: _pages.length + 1,
                onPageChanged: (idx) => setState(() => _currentPage = idx),
                itemBuilder: (context, index) {
                  if (index < _pages.length) {
                    final page = _pages[index];
                    return Padding(
                      padding: const EdgeInsets.all(40.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(32),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.1)
                                  : Colors.black.withValues(alpha: 0.05),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              page.icon,
                              size: 80,
                              color: isDark ? Colors.white70 : Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 48),
                          Text(
                            page.title,
                            style: GoogleFonts.playfairDisplay(
                              fontSize: 32,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            page.description,
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              color: textColor.withOpacity(0.6),
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    );
                  }
                  return _buildPreferencesPage(isDark, textColor);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(32.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: List.generate(
                      _pages.length + 1,
                      (index) => AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        height: 8,
                        width: _currentPage == index ? 24 : 8,
                        decoration: BoxDecoration(
                          color: _currentPage == index
                              ? (isDark ? Colors.white70 : Colors.black87)
                              : Colors.grey.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      if (_currentPage < _pages.length) {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      } else {
                        _finishOnboarding();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? Colors.white : Colors.black87,
                      foregroundColor: isDark ? Colors.black : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 16,
                      ),
                    ),
                    child: Text(
                      _currentPage < _pages.length ? "Next" : "Get Started",
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreferencesPage(bool isDark, Color textColor) {
    final chipBg = isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.04);
    final selectedBg = isDark ? Colors.white24 : Colors.black26;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Text(
            "What do you like to read?",
            style: GoogleFonts.playfairDisplay(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: textColor,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "We'll personalize your feed based on your interests.",
            style: GoogleFonts.inter(
              fontSize: 15,
              color: textColor.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            "Writing Types",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: WritingType.values.map((wt) {
              final key = wt.name;
              final selected = _selectedWritingTypes.contains(key);
              return FilterChip(
                label: Text(wt.displayName),
                selected: selected,
                onSelected: (v) {
                  setState(() {
                    if (v) {
                      _selectedWritingTypes.add(key);
                    } else {
                      _selectedWritingTypes.remove(key);
                    }
                  });
                },
                backgroundColor: chipBg,
                selectedColor: selectedBg,
                checkmarkColor: textColor,
                labelStyle: TextStyle(color: textColor, fontSize: 13),
              );
            }).toList(),
          ),
          const SizedBox(height: 24),
          Text(
            "Formats",
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
          ),
          const SizedBox(height: 12),
          ...WritingType.values.expand((wt) {
            final subtypes = getDisplaySubtypesForWritingType(wt);
            return [
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 6),
                child: Text(
                  wt.displayName,
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    color: textColor.withValues(alpha: 0.4),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: subtypes.map((label) {
                  final selected = _selectedSubtypes.contains(label);
                  return FilterChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (v) {
                      setState(() {
                        if (v) {
                          _selectedSubtypes.add(label);
                        } else {
                          _selectedSubtypes.remove(label);
                        }
                      });
                    },
                    backgroundColor: chipBg,
                    selectedColor: selectedBg,
                    checkmarkColor: textColor,
                    labelStyle: TextStyle(color: textColor, fontSize: 13),
                  );
                }).toList(),
              ),
            ];
          }),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class OnboardingItem {
  final String title;
  final String description;
  final IconData icon;

  OnboardingItem({
    required this.title,
    required this.description,
    required this.icon,
  });
}
