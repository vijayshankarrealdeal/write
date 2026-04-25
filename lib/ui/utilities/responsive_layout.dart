import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Breakpoints for responsive design (mobile / tablet / desktop).
class Breakpoints {
  static const double mobile = 650;
  static const double tablet = 1100;

  static bool isMobile(double width) => width < mobile;
  static bool isTablet(double width) => width >= mobile && width < tablet;
  static bool isDesktop(double width) => width >= tablet;
}

class ResponsiveLayout extends StatelessWidget {
  final Widget mobileScaffold;
  final Widget tabletScaffold;
  final Widget desktopScaffold;

  const ResponsiveLayout({
    super.key,
    required this.mobileScaffold,
    required this.tabletScaffold,
    required this.desktopScaffold,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (Breakpoints.isMobile(width)) {
          return mobileScaffold;
        } else if (Breakpoints.isTablet(width)) {
          return tabletScaffold;
        } else {
          return desktopScaffold;
        }
      },
    );
  }
}

/// Returns current breakpoint based on MediaQuery.
BreakpointType getBreakpoint(BuildContext context) {
  final width = MediaQuery.sizeOf(context).width;
  if (Breakpoints.isMobile(width)) return BreakpointType.mobile;
  if (Breakpoints.isTablet(width)) return BreakpointType.tablet;
  return BreakpointType.desktop;
}

enum BreakpointType { mobile, tablet, desktop }
