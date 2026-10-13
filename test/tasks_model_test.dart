/// Tasks as the client reads them: the extension's flat `CreateTaskResult`
/// and the 2025-11-25 core's nested one, polled `tasks/get` results, and the
/// protocol [TaskStatus].
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('Tasks model (client)', () {
    test('the extension\'s CreateTaskResult (flat, resultType: task)', () {
      final result = <String, dynamic>{
        'resultType': 'task',
        'taskId': 't-1',
        'status': 'working',
        'createdAt': '2026-07-28T00:00:00Z',
        'lastUpdatedAt': '2026-07-28T00:00:00Z',
        'ttlMs': null,
        'pollIntervalMs': 1000,
      };
      expect(McpResultType.of(result), McpResultType.task);
      final task = taskOf(result);
      expect(task.taskId, 't-1');
      expect(task.status, TaskStatus.working);
      expect(task.status.isTerminal, isFalse);
      expect(task.pollIntervalMs, 1000);
      expect(task.has('ttlMs'), isTrue);
      expect(task.ttlMs, isNull);
    });

    test('the 2025-11-25 core CreateTaskResult (nested task)', () {
      final task = taskOf({
        'task': {
          'taskId': 't-9',
          'status': 'working',
          'createdAt': 'a',
          'lastUpdatedAt': 'b',
          'ttl': 60000,
          'pollInterval': 500,
        },
      });
      expect(task.taskId, 't-9');
      expect(task.ttl, 60000);
      expect(task.pollInterval, 500);
    });

    test('a completed tasks/get result carries its result', () {
      final t = GetTaskResult.fromJson({
        'taskId': 't-2',
        'status': 'completed',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'ttlMs': 5000,
        'result': {
          'content': [
            {'type': 'text', 'text': 'done'}
          ],
        },
      });
      expect(t.status, TaskStatus.completed);
      expect(t.isTerminal, isTrue);
      expect(t['result'], isA<Map>());
    });

    test('an input_required task carries its input requests', () {
      final t = GetTaskResult.fromJson({
        'taskId': 't-3',
        'status': 'input_required',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'statusMessage': 'need input',
        'ttlMs': 1000,
        'pollIntervalMs': 500,
        'inputRequests': {
          'req-1': {
            'method': 'elicitation/create',
            'params': {'message': 'Name?', 'requestedSchema': {'type': 'object', 'properties': {}}},
          },
        },
      });
      expect(t.status, TaskStatus.inputRequired);
      expect(t.statusMessage, 'need input');
      expect(t['inputRequests'], isA<Map>());
      expect(t.toJson()['pollIntervalMs'], 500);
    });

    test('a failed task carries its error', () {
      final t = GetTaskResult.fromJson({
        'taskId': 't-4',
        'status': 'failed',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'error': {'code': -32000, 'message': 'boom'},
      });
      expect(t.isTerminal, isTrue);
      expect(t.toJson()['error'], {'code': -32000, 'message': 'boom'});
    });

    test('status values, terminal states, unknown status kept', () {
      expect(tasksExtensionId, 'io.modelcontextprotocol/tasks');
      expect(TaskStatus.of('input_required'), same(TaskStatus.inputRequired));
      expect(TaskStatus.cancelled.value, 'cancelled');
      expect(TaskStatus.working.isTerminal, isFalse);
      expect(TaskStatus.inputRequired.isTerminal, isFalse);
      expect(TaskStatus.completed.isTerminal, isTrue);
      expect(TaskStatus.failed.isTerminal, isTrue);
      expect(TaskStatus.cancelled.isTerminal, isTrue);
      expect(TaskStatus.of('paused').value, 'paused');
    });
  });
}
