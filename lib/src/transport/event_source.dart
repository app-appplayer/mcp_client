library;

/// Export the appropriate implementation based on platform
export 'event_source_stub.dart'
    if (dart.library.io) 'event_source_io.dart'
    if (dart.library.html) 'event_source_web.dart';
