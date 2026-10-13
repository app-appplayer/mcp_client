/// Server-Sent Events parsing (the WHATWG event stream format), as the
/// Streamable HTTP and HTTP+SSE transports receive it.
library;

import 'dart:async';

/// One dispatched event.
class SseEvent {
  const SseEvent({this.id, this.event = 'message', this.data = '', this.retry});

  /// The `id` field, when the event set one.
  final String? id;

  /// The event type (`message` unless named).
  final String event;

  /// The data lines, joined with newlines.
  final String data;

  /// A reconnection time the server asked for.
  final Duration? retry;
}

/// Turns lines (as `LineSplitter` produces them) into events: fields
/// `data` (accumulated), `id`, `event`, `retry`; `:` comments ignored; an
/// empty line dispatches. An event with an id and no data (a priming event)
/// is dispatched with empty [SseEvent.data] so its id can be recorded.
class SseParser extends StreamTransformerBase<String, SseEvent> {
  const SseParser();

  @override
  Stream<SseEvent> bind(Stream<String> lines) async* {
    final data = <String>[];
    String? id;
    String? event;
    Duration? retry;
    var sawField = false;

    SseEvent? dispatch() {
      if (!sawField) return null;
      final e = SseEvent(id: id, event: event ?? 'message', data: data.join('\n'), retry: retry);
      data.clear();
      id = null;
      event = null;
      retry = null;
      sawField = false;
      return e;
    }

    var first = true;
    await for (var line in lines) {
      if (first) {
        first = false;
        if (line.startsWith('﻿')) line = line.substring(1);
      }
      if (line.isEmpty) {
        final e = dispatch();
        if (e != null) yield e;
        continue;
      }
      if (line.startsWith(':')) continue;
      final colon = line.indexOf(':');
      final field = colon < 0 ? line : line.substring(0, colon);
      var value = colon < 0 ? '' : line.substring(colon + 1);
      if (value.startsWith(' ')) value = value.substring(1);
      switch (field) {
        case 'data':
          data.add(value);
          sawField = true;
        case 'id':
          if (!value.contains('\u0000')) id = value;
          sawField = true;
        case 'event':
          event = value;
          sawField = true;
        case 'retry':
          final ms = int.tryParse(value);
          if (ms != null && ms >= 0) retry = Duration(milliseconds: ms);
          sawField = true;
      }
    }
    final e = dispatch();
    if (e != null && e.data.isNotEmpty) yield e;
  }
}
