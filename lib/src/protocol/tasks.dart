/// Tasks: the 2025-11-25 core tasks and the 2026-07-28 tasks extension
/// (`io.modelcontextprotocol/tasks`, SEP-2663) share the protocol [Task] /
/// [TaskStatus] models (generated). This file holds the client's helpers.
library;

import '../schema/schema.g.dart';

/// The tasks extension identifier (2026-07-28).
const String tasksExtensionId = 'io.modelcontextprotocol/tasks';

/// Lifecycle helpers on the protocol [TaskStatus].
extension TaskStatusLifecycle on TaskStatus {
  /// `completed`, `failed` or `cancelled`: no further transitions.
  bool get isTerminal =>
      this == TaskStatus.completed ||
      this == TaskStatus.failed ||
      this == TaskStatus.cancelled;
}

/// Lifecycle helper on a task (2.x `Task.isTerminal`).
extension TaskLifecycle on Task {
  /// Whether the task reached a terminal state.
  bool get isTerminal => status.isTerminal;
}

/// Lifecycle helper on a polled task.
extension GetTaskResultLifecycle on GetTaskResult {
  /// Whether the task reached a terminal state.
  bool get isTerminal => status.isTerminal;
}

/// The task a `CreateTaskResult` announces, in either form: the 2025-11-25
/// core nests it under `task`; the 2026-07-28 extension puts its fields on
/// the result itself.
Task taskOf(Map<String, dynamic> createTaskResult) {
  final nested = createTaskResult['task'];
  return Task.fromJson(nested is Map
      ? Map<String, Object?>.from(nested)
      : Map<String, Object?>.from(createTaskResult));
}
