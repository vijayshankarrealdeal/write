import 'package:flutter/material.dart';

class GrowShrinkButton extends StatelessWidget {
  const GrowShrinkButton({
    super.key,
    required this.grow,
    required this.textColor,
    required this.onPressed,
  });

  final bool grow;
  final Color textColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: grow ? 'Grow font' : 'Shrink font',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onPressed,
        child: SizedBox(
          width: 32,
          height: 28,
          child: Center(
            child: RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: TextStyle(color: textColor),
                children: [
                  TextSpan(
                    text: 'A',
                    style: TextStyle(
                      fontSize: grow ? 16 : 11,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  WidgetSpan(
                    alignment: PlaceholderAlignment.top,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 1, top: 1),
                      child: Icon(
                        grow ? Icons.arrow_upward : Icons.arrow_downward,
                        size: 10,
                        color: textColor,
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
}
