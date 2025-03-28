import 'dart:io';

enum LogLevel {
  none,
  error,
  warning,
  info,
  debug,
  trace,
}

final log = Logger.instance;

class Logger {
  static final Logger _instance = Logger._internal();
  static Logger get instance => _instance;

  LogLevel _currentLevel = LogLevel.none;
  bool _includeTimestamp = true;
  bool _useColor = true;

  static const String _resetColor = '\u001b[0m';
  static const String _redColor = '\u001b[31m';
  static const String _yellowColor = '\u001b[33m';
  static const String _blueColor = '\u001b[34m';
  static const String _cyanColor = '\u001b[36m';
  static const String _grayColor = '\u001b[90m';

  Logger._internal();

  void configure({
    LogLevel? level,
    bool? includeTimestamp,
    bool? useColor,
  }) {
    if (level != null) _currentLevel = level;
    if (includeTimestamp != null) _includeTimestamp = includeTimestamp;
    if (useColor != null) _useColor = useColor;
  }

  void setLevel(LogLevel level) {
    _currentLevel = level;
  }

  void setIncludeTimestamp(bool include) {
    _includeTimestamp = include;
  }

  void setUseColor(bool use) {
    _useColor = use;
  }

  void log(LogLevel level, String message) {
    if (level.index <= _currentLevel.index) {
      final timestamp = _includeTimestamp ? '[${DateTime.now()}] ' : '';
      final levelName = level.name.toUpperCase();
      final colorCode = _getColorForLevel(level);

      if (_useColor) {
        stderr.writeln('$timestamp$colorCode[$levelName]$_resetColor $message');
      } else {
        stderr.writeln('$timestamp[$levelName] $message');
      }
    }
  }

  void error(String message) {
    log(LogLevel.error, message);
  }

  void warning(String message) {
    log(LogLevel.warning, message);
  }

  void info(String message) {
    log(LogLevel.info, message);
  }

  void debug(String message) {
    log(LogLevel.debug, message);
  }

  void trace(String message) {
    log(LogLevel.trace, message);
  }

  String _getColorForLevel(LogLevel level) {
    if (!_useColor) return '';

    switch (level) {
      case LogLevel.error:
        return _redColor;
      case LogLevel.warning:
        return _yellowColor;
      case LogLevel.info:
        return _blueColor;
      case LogLevel.debug:
        return _cyanColor;
      case LogLevel.trace:
        return _grayColor;
      default:
        return _resetColor;
    }
  }
}