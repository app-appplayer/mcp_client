// Fixture: a stdio server that ignores both its input closing and SIGTERM,
// recording each. Only SIGKILL ends it. Arguments: <marker file>.
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final marker = File(args.single);
  marker.writeAsStringSync('pid:$pid\n');
  ProcessSignal.sigterm.watch().listen((_) {
    marker.writeAsStringSync('sigterm\n', mode: FileMode.append);
  });
  stdin.listen((_) {}, onDone: () {
    marker.writeAsStringSync('stdin-closed\n', mode: FileMode.append);
  });
  await Completer<void>().future; // never exits on its own
}
