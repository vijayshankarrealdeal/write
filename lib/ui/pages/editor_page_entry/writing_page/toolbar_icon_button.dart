import 'package:flutter/material.dart';

class ToolbarIconButton extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String tooltip;
  final Color color;
  final VoidCallback onPressed;

  const ToolbarIconButton({
    super.key,
    this.icon,
    this.iconWidget,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  }) : assert(icon != null || iconWidget != null,
            'Provide either icon or iconWidget');

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: iconWidget ?? Icon(icon, size: 19, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
      splashRadius: 18,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
      padding: const EdgeInsets.all(6),
    );
  }
}

class OutlineHeading {
  final String text;
  final int level;
  final int offset;
  const OutlineHeading({
    required this.text,
    required this.level,
    required this.offset,
  });
}
