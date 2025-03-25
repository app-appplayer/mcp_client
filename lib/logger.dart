import 'dart:io';

enum LogLevel {
  none,
  error,
  warning,
  info,
  debug,
  trace,
}

class Logger {
  static LogLevel currentLevel = LogLevel.none;

  static void log(LogLevel level, String message) {
    if (level.index <= currentLevel.index) {
      stderr.writeln('[${level.name.toUpperCase()}] $message');
    }
  }

  static void error(String message) {
    log(LogLevel.error, message);
  }

  static void warning(String message) {
    log(LogLevel.warning, message);
  }

  static void info(String message) {
    log(LogLevel.info, message);
  }

  static void debug(String message) {
    log(LogLevel.debug, message);
  }

  static void trace(String message) {
    log(LogLevel.trace, message);
  }
}