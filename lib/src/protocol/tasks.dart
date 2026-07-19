/// Tasks extension (`io.modelcontextprotocol/tasks`, MCP 2026-07-28) — client.
///
/// When a server answers a request with a `CreateTaskResult` (`resultType:
/// "task"`), the client receives a [Task] handle and tracks it via `tasks/get`
/// (poll), `tasks/update` (deliver input responses to an `input_required`
/// task), and `tasks/cancel`. `tasks/list` is intentionally absent. Delivered
/// as a negotiated extension; dormant unless advertised in
/// `capabilities.extensions`. Shapes mirror `ext-tasks` `schema/draft/schema.ts`.
library;

/// Reverse-DNS identifier for the tasks extension (a key in
/// `capabilities.extensions`, empty settings object).
const String tasksExtensionId = 'io.modelcontextprotocol/tasks';

/// Lifecycle status of a [Task].
enum TaskStatus {
  working,
  inputRequired,
  completed,
  failed,
  cancelled;

  String get wire => switch (this) {
        TaskStatus.working => 'working',
        TaskStatus.inputRequired => 'input_required',
        TaskStatus.completed => 'completed',
        TaskStatus.failed => 'failed',
        TaskStatus.cancelled => 'cancelled',
      };

  bool get isTerminal =>
      this == TaskStatus.completed ||
      this == TaskStatus.failed ||
      this == TaskStatus.cancelled;

  static TaskStatus fromWire(String s) => switch (s) {
        'working' => TaskStatus.working,
        'input_required' => TaskStatus.inputRequired,
        'completed' => TaskStatus.completed,
        'failed' => TaskStatus.failed,
        'cancelled' => TaskStatus.cancelled,
        _ => throw ArgumentError('Unknown task status: $s'),
      };
}

/// A task handle / detailed state as returned by a `CreateTaskResult` or a
/// `tasks/get` response.
class Task {
  final String taskId;
  final TaskStatus status;
  final String? statusMessage;
  final String createdAt;
  final String lastUpdatedAt;
  final int? ttlMs;
  final int? pollIntervalMs;

  /// `input_required`: server→client requests keyed by id.
  final Map<String, dynamic>? inputRequests;

  /// `completed`: the terminal result payload.
  final Map<String, dynamic>? result;

  /// `failed`: the JSON-RPC error object.
  final Map<String, dynamic>? error;

  const Task({
    required this.taskId,
    required this.status,
    required this.createdAt,
    required this.lastUpdatedAt,
    this.statusMessage,
    this.ttlMs,
    this.pollIntervalMs,
    this.inputRequests,
    this.result,
    this.error,
  });

  bool get isTerminal => status.isTerminal;

  factory Task.fromJson(Map<String, dynamic> json) => Task(
        taskId: json['taskId'] as String,
        status: TaskStatus.fromWire(json['status'] as String),
        createdAt: json['createdAt'] as String,
        lastUpdatedAt: json['lastUpdatedAt'] as String,
        statusMessage: json['statusMessage'] as String?,
        ttlMs: json['ttlMs'] as int?,
        pollIntervalMs: json['pollIntervalMs'] as int?,
        inputRequests: (json['inputRequests'] as Map?)
            ?.map((k, v) => MapEntry(k as String, v)),
        result: (json['result'] as Map?)?.cast<String, dynamic>(),
        error: (json['error'] as Map?)?.cast<String, dynamic>(),
      );

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{
      'taskId': taskId,
      'status': status.wire,
      'createdAt': createdAt,
      'lastUpdatedAt': lastUpdatedAt,
      'ttlMs': ttlMs,
    };
    if (statusMessage != null) json['statusMessage'] = statusMessage;
    if (pollIntervalMs != null) json['pollIntervalMs'] = pollIntervalMs;
    if (inputRequests != null) json['inputRequests'] = inputRequests;
    if (result != null) json['result'] = result;
    if (error != null) json['error'] = error;
    return json;
  }
}
