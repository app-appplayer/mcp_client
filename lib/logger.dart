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
  static final Map<String, Logger> _loggers = {};

  static final Logger _instance = Logger._internal('mcp_client');
  static Logger get instance => _instance;

  final String name;

  LogLevel _level = LogLevel.none;
  bool _includeTimestamp = true;
  bool _useColor = true;
  IOSink _output = stderr;

  static const String _resetColor = '\u001b[0m';
  static const String _redColor = '\u001b[31m';
  static const String _yellowColor = '\u001b[33m';
  static const String _blueColor = '\u001b[34m';
  static const String _cyanColor = '\u001b[36m';
  static const String _grayColor = '\u001b[90m';

  static Logger getLogger(String name) {
    return _loggers.putIfAbsent(name, () => Logger._internal(name));
  }

  Logger._internal(this.name) {
    _loggers[name] = this;
  }

  static void setAllLevels(LogLevel level) {
    for (final logger in _loggers.values) {
      logger._level = level;
    }
  }

  static void setLevelByPattern(String pattern, LogLevel level) {
    for (final entry in _loggers.entries) {
      if (entry.key.startsWith(pattern)) {
        entry.value._level = level;
      }
    }
  }

  void configure({
    LogLevel? level,
    bool? includeTimestamp,
    bool? useColor,
    IOSink? output,
  }) {
    if (level != null) {
      _level = level;

      setAllLevels(level);
    }
    if (includeTimestamp != null) _includeTimestamp = includeTimestamp;
    if (useColor != null) _useColor = useColor;
    if (output != null) _output = output;
  }

  void setLevel(LogLevel level) {
    _level = level;
  }

  void log(LogLevel level, String message) {
    if (level.index <= _level.index) {
      final timestamp = _includeTimestamp ? '[${DateTime.now()}] ' : '';
      final levelName = level.name.toUpperCase();
      final colorCode = _getColorForLevel(level);
      final namePrefix = name.isNotEmpty ? '[$name] ' : '';

      if (_useColor) {
        _output.writeln('$timestamp$colorCode[$levelName]$_resetColor $namePrefix$message');
      } else {
        _output.writeln('$timestamp[$levelName] $namePrefix$message');
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