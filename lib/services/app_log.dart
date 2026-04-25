import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';

/// App-wide logger instance. Use via `log.d/i/w/e/f(...)`.
///
/// Colors off — Chrome DevTools renders raw ANSI as garbled text, which
/// defeats the purpose of PrettyPrinter on web builds.
final Logger log = Logger(
  level: kReleaseMode ? Level.info : Level.trace,
  printer: PrettyPrinter(
    methodCount: 0,
    errorMethodCount: 8,
    lineLength: 100,
    colors: false,
    printEmojis: true,
    dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
  ),
);
