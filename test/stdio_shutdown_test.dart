/// stdio shutdown (specification, basic/lifecycle): the client closes the
/// server's input first, waits, then sends SIGTERM, then SIGKILL.
@TestOn('vm && !windows')
library;

import 'dart:io';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

Future<bool> _alive(int pid) async =>
    (await Process.run('ps', ['-p', '$pid'])).exitCode == 0;

int _pidOf(File marker) =>
    int.parse(RegExp(r'pid:(\d+)').firstMatch(marker.readAsStringSync())!.group(1)!);

Future<void> _waitFor(Future<bool> Function() ok, Duration within) async {
  final end = DateTime.now().add(within);
  while (!await ok()) {
    if (DateTime.now().isAfter(end)) fail('condition not met within $within');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('stdio_shutdown'));
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(StdioClientTransport, File)> start(String fixture) async {
    final marker = File('${dir.path}/marker');
    final transport = await StdioClientTransport.create(
      command: Platform.resolvedExecutable,
      arguments: ['run', 'test/support/$fixture', marker.path],
    );
    await _waitFor(() async => marker.existsSync() && marker.readAsStringSync().contains('pid:'),
        const Duration(seconds: 30));
    return (transport, marker);
  }

  test('a server that exits on end of input is not signalled', () async {
    final (transport, marker) = await start('stdio_exit_on_eof.dart');
    final pid = _pidOf(marker);
    transport.close();
    await _waitFor(() async => !await _alive(pid), const Duration(seconds: 5));
    final log = marker.readAsStringSync();
    expect(log, contains('stdin-closed'));
    expect(log, isNot(contains('sigterm')));
  });

  test('a server that ignores input close and SIGTERM is SIGKILLed', () async {
    final (transport, marker) = await start('stdio_ignores_sigterm.dart');
    final pid = _pidOf(marker);
    transport.close();
    await _waitFor(() async => !await _alive(pid), const Duration(seconds: 10));
    final log = marker.readAsStringSync();
    expect(log, contains('stdin-closed'));
    expect(log, contains('sigterm'));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
