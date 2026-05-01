import 'package:flutter/cupertino.dart';

class AppSpinner extends StatelessWidget {
  const AppSpinner({super.key, this.size, this.color});

  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final radius = size != null ? size! / 2 : 10.0;
    return CupertinoActivityIndicator(
      radius: radius,
      color: color,
    );
  }
}
