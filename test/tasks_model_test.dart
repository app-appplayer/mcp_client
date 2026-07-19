/// Tasks extension (MCP 2026-07-28) — client Task handle parsing.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('Tasks model (client)', () {
    test('parses a CreateTaskResult (resultType:task) into a Task handle', () {
      final createTaskResult = <String, dynamic>{
        'resultType': 'task',
        'taskId': 't-1',
        'status': 'working',
        'createdAt': '2026-07-28T00:00:00Z',
        'lastUpdatedAt': '2026-07-28T00:00:00Z',
        'ttlMs': null,
        'pollIntervalMs': 1000,
      };
      expect(McpResultType.of(createTaskResult), McpResultType.task);
      final task = Task.fromJson(createTaskResult);
      expect(task.taskId, 't-1');
      expect(task.status, TaskStatus.working);
      expect(task.isTerminal, isFalse);
      expect(task.pollIntervalMs, 1000);
    });

    test('parses a completed tasks/get result', () {
      final t = Task.fromJson({
        'taskId': 't-2',
        'status': 'completed',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'ttlMs': 5000,
        'result': {'content': [{'type': 'text', 'text': 'done'}]},
      });
      expect(t.status, TaskStatus.completed);
      expect(t.isTerminal, isTrue);
      expect(t.result!['content'], isA<List>());
    });

    test('extension id + status round-trip', () {
      expect(tasksExtensionId, 'io.modelcontextprotocol/tasks');
      expect(TaskStatus.fromWire('input_required'), TaskStatus.inputRequired);
      expect(TaskStatus.cancelled.wire, 'cancelled');
    });

    test('TaskStatus.wire covers every enum value', () {
      expect(TaskStatus.working.wire, 'working');
      expect(TaskStatus.inputRequired.wire, 'input_required');
      expect(TaskStatus.completed.wire, 'completed');
      expect(TaskStatus.failed.wire, 'failed');
      expect(TaskStatus.cancelled.wire, 'cancelled');
    });

    test('TaskStatus.fromWire covers every wire value and rejects unknown',
        () {
      expect(TaskStatus.fromWire('working'), TaskStatus.working);
      expect(TaskStatus.fromWire('input_required'), TaskStatus.inputRequired);
      expect(TaskStatus.fromWire('completed'), TaskStatus.completed);
      expect(TaskStatus.fromWire('failed'), TaskStatus.failed);
      expect(TaskStatus.fromWire('cancelled'), TaskStatus.cancelled);
      expect(
        () => TaskStatus.fromWire('bogus'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('TaskStatus.isTerminal is true only for completed/failed/cancelled',
        () {
      expect(TaskStatus.working.isTerminal, isFalse);
      expect(TaskStatus.inputRequired.isTerminal, isFalse);
      expect(TaskStatus.completed.isTerminal, isTrue);
      expect(TaskStatus.failed.isTerminal, isTrue);
      expect(TaskStatus.cancelled.isTerminal, isTrue);
    });

    test('Task.fromJson parses inputRequests and toJson round-trips', () {
      final task = Task.fromJson({
        'taskId': 't-3',
        'status': 'input_required',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'statusMessage': 'need input',
        'ttlMs': 1000,
        'pollIntervalMs': 500,
        'inputRequests': {
          'req-1': {'method': 'elicitation/create', 'params': {}},
        },
      });
      expect(task.status, TaskStatus.inputRequired);
      expect(task.statusMessage, 'need input');
      expect(task.ttlMs, 1000);
      expect(task.inputRequests, isNotNull);
      expect(task.inputRequests!['req-1'], isA<Map>());

      final json = task.toJson();
      expect(json['taskId'], 't-3');
      expect(json['status'], 'input_required');
      expect(json['statusMessage'], 'need input');
      expect(json['pollIntervalMs'], 500);
      expect(json['inputRequests'], task.inputRequests);
    });

    test('Task.fromJson parses a failed task with error payload', () {
      final task = Task.fromJson({
        'taskId': 't-4',
        'status': 'failed',
        'createdAt': 'a',
        'lastUpdatedAt': 'b',
        'error': {'code': -32000, 'message': 'boom'},
      });
      expect(task.status, TaskStatus.failed);
      expect(task.isTerminal, isTrue);
      expect(task.error, {'code': -32000, 'message': 'boom'});

      final json = task.toJson();
      expect(json['error'], {'code': -32000, 'message': 'boom'});
    });
  });
}
