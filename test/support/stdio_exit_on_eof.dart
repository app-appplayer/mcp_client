// Fixture: a stdio server that exits when its input closes, recording that it
// saw the close. Arguments: <marker file>.
import 'dart:io';

Future<void> main(List<String> args) async {
  final marker = File(args.single);
  marker.writeAsStringSync('pid:$pid\n');
  await stdin.drain<void>();
  marker.writeAsStringSync('stdin-closed\n', mode: FileMode.append);
  exit(0);
}
