// Re-export logging package
export 'package:logging/logging.dart';

import 'package:logging/logging.dart';

// Extension methods for backward compatibility
extension LoggerExtensions on Logger {
  void debug(String message) => fine(message);
  void error(String message) => severe(message);
  void warn(String message) => warning(message);
}
