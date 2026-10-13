// Generated from `Client` by forwarding each public member; when `Client`
// gains a member, this class must gain it too (the `implements` clause makes
// a missing one a compile error).
import 'dart:async';

import '../models/models.dart';
import '../protocol/multi_round_trip.dart';
import '../transport/transport.dart';
import 'client.dart';

/// A [Client] that hands every call to [inner]. Extend it to wrap a client —
/// add caching, limits or logging — and override only the members that
/// change; everything else, including members later versions add, reaches
/// [inner] unchanged.
///
/// ```dart
/// class CountingClient extends DelegatingClient {
///   CountingClient(super.inner);
///   int calls = 0;
///
///   @override
///   Future<CallToolResult> callTool(String name, Map<String, dynamic> toolArguments,
///       {Map<String, dynamic>? meta, RequestOptions? options}) {
///     calls++;
///     return super.callTool(name, toolArguments, meta: meta, options: options);
///   }
/// }
/// ```
class DelegatingClient implements Client {
  DelegatingClient(this.inner);

  /// The client every call goes to.
  final Client inner;

  @override
  String get name => inner.name;

  @override
  String get version => inner.version;

  @override
  String? get description => inner.description;

  @override
  ClientCapabilities get capabilities => inner.capabilities;

  @override
  String get protocolVersion => inner.protocolVersion;

  @override
  bool get isConnected => inner.isConnected;

  @override
  bool get isStateless => inner.isStateless;

  @override
  ServerCapabilities? get serverCapabilities => inner.serverCapabilities;

  @override
  Map<String, dynamic>? get serverInfo => inner.serverInfo;

  @override
  String? get title => inner.title;

  @override
  String? get websiteUrl => inner.websiteUrl;

  @override
  List<McpIcon>? get icons => inner.icons;

  @override
  Duration get requestTimeout => inner.requestTimeout;

  @override
  Duration get maxRequestTimeout => inner.maxRequestTimeout;

  @override
  Stream<ServerInfo> get onConnect => inner.onConnect;

  @override
  Stream<DisconnectReason> get onDisconnect => inner.onDisconnect;

  @override
  Stream<McpError> get onError => inner.onError;

  @override
  Future<void> connect(
    ClientTransport transport, {
    ProtocolEra era = ProtocolEra.auto,
    @Deprecated(
      'Use era: ProtocolEra.modern (true) or ProtocolEra.legacy (false).',
    )
    bool? statelessMode,
  }) =>
      // ignore: deprecated_member_use_from_same_package
      inner.connect(transport, era: era, statelessMode: statelessMode);

  @override
  ProtocolEra get era => inner.era;

  @override
  Duration? get eraProbeTimeout => inner.eraProbeTimeout;

  @override
  set eraProbeTimeout(Duration? value) => inner.eraProbeTimeout = value;

  @override
  Future<void> connectWithRetry(
    Future<ClientTransport> Function() openTransport, {
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 2),
    ProtocolEra era = ProtocolEra.auto,
  }) => inner.connectWithRetry(
    openTransport,
    maxRetries: maxRetries,
    delay: delay,
    era: era,
  );

  @override
  Future<void> initialize() => inner.initialize();

  @override
  String? get negotiatedProtocolVersion => inner.negotiatedProtocolVersion;

  @override
  Future<DiscoverResult> discover({RequestOptions? options}) =>
      inner.discover(options: options);

  @override
  bool get supportsTasks => inner.supportsTasks;

  @override
  Task? taskFromResult(Map<String, dynamic> result) =>
      inner.taskFromResult(result);

  @override
  Future<GetTaskResult> getTask(
    String taskId, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.getTask(taskId, meta: meta, options: options);

  @override
  Future<void> updateTask(
    String taskId,
    Map<String, dynamic> inputResponses, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.updateTask(taskId, inputResponses, meta: meta, options: options);

  @override
  Future<Task?> cancelTask(
    String taskId, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.cancelTask(taskId, meta: meta, options: options);

  @override
  Future<List<Tool>> listTools({
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listTools(meta: meta, options: options);

  @override
  Future<ListToolsResult> listToolsPage({
    String? cursor,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listToolsPage(cursor: cursor, meta: meta, options: options);

  @override
  bool get validateToolOutput => inner.validateToolOutput;

  @override
  set validateToolOutput(bool value) => inner.validateToolOutput = value;

  @override
  Future<CallToolResult> callTool(
    String name,
    Map<String, dynamic> toolArguments, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.callTool(name, toolArguments, meta: meta, options: options);

  @override
  Future<Task> callToolAsTask(
    String name,
    Map<String, dynamic> toolArguments, {
    int? ttl,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.callToolAsTask(
    name,
    toolArguments,
    ttl: ttl,
    meta: meta,
    options: options,
  );

  @override
  Future<Map<String, dynamic>> taskResult(
    String taskId, {
    RequestOptions? options,
  }) => inner.taskResult(taskId, options: options);

  @override
  Future<ListTasksResult> listTasksPage({
    String? cursor,
    RequestOptions? options,
  }) => inner.listTasksPage(cursor: cursor, options: options);

  @override
  Future<ToolCallTracking> callToolWithTracking(
    String name,
    Map<String, dynamic> arguments, {
    bool trackProgress = true,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.callToolWithTracking(
    name,
    arguments,
    trackProgress: trackProgress,
    meta: meta,
    options: options,
  );

  @override
  void notifyCancelled(Object requestId, {String? reason}) =>
      inner.notifyCancelled(requestId, reason: reason);

  @override
  void notifyProgress(
    dynamic progressToken,
    double progress, {
    double? total,
    String? message,
  }) => inner.notifyProgress(
    progressToken,
    progress,
    total: total,
    message: message,
  );

  @override
  Future<List<Resource>> listResources({
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listResources(meta: meta, options: options);

  @override
  Future<ListResourcesResult> listResourcesPage({
    String? cursor,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listResourcesPage(cursor: cursor, meta: meta, options: options);

  @override
  Future<ReadResourceResult> readResource(
    String uri, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.readResource(uri, meta: meta, options: options);

  @override
  Future<ReadResourceResult> getResourceWithTemplate(
    String templateUri,
    Map<String, dynamic> params, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.getResourceWithTemplate(
    templateUri,
    params,
    meta: meta,
    options: options,
  );

  @override
  Future<void> subscribeResource(
    String uri, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.subscribeResource(uri, meta: meta, options: options);

  @override
  Future<void> unsubscribeResource(
    String uri, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.unsubscribeResource(uri, meta: meta, options: options);

  @override
  Future<List<ResourceTemplate>> listResourceTemplates({
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listResourceTemplates(meta: meta, options: options);

  @override
  Future<ListResourceTemplatesResult> listResourceTemplatesPage({
    String? cursor,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listResourceTemplatesPage(
    cursor: cursor,
    meta: meta,
    options: options,
  );

  @override
  Future<List<Prompt>> listPrompts({
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listPrompts(meta: meta, options: options);

  @override
  Future<ListPromptsResult> listPromptsPage({
    String? cursor,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.listPromptsPage(cursor: cursor, meta: meta, options: options);

  @override
  Future<GetPromptResult> getPrompt(
    String name, [
    Map<String, dynamic>? promptArguments,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  ]) => inner.getPrompt(name, promptArguments, meta, options);

  @override
  void onSamplingRequest(
    Future<CreateMessageResult> Function(CreateMessageRequestParams request)
    handler,
  ) => inner.onSamplingRequest(handler);

  @override
  void onSamplingRequestMap(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) => inner.onSamplingRequestMap(handler);

  @override
  void onElicitationRequest(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) => inner.onElicitationRequest(handler);

  @override
  void onElicitationRequestTyped(
    Future<ElicitResult> Function(ElicitRequestParams request) handler,
  ) => inner.onElicitationRequestTyped(handler);

  @override
  void onListRoots(Future<List<Root>> Function() handler) =>
      inner.onListRoots(handler);

  @override
  void onListRootsMap(Future<List<Map<String, dynamic>>> Function() handler) =>
      inner.onListRootsMap(handler);

  @override
  List<Root> get roots => inner.roots;

  @override
  void addRoot(Root root) => inner.addRoot(root);

  @override
  void addRootMap(Map<String, dynamic> root) => inner.addRootMap(root);

  @override
  void removeRoot(String uri) => inner.removeRoot(uri);

  @override
  Future<void> setLoggingLevel(
    McpLogLevel level, {
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.setLoggingLevel(level, meta: meta, options: options);

  @override
  Future<void> ping({Map<String, dynamic>? meta, RequestOptions? options}) =>
      inner.ping(meta: meta, options: options);

  @override
  Future<CompleteResult> complete(
    Map<String, dynamic> ref,
    Map<String, dynamic> argument, {
    Map<String, dynamic>? context,
    Map<String, dynamic>? meta,
    RequestOptions? options,
  }) => inner.complete(
    ref,
    argument,
    context: context,
    meta: meta,
    options: options,
  );

  @override
  void onNotification(String method, Function(Map<String, dynamic>) handler) =>
      inner.onNotification(method, handler);

  @override
  void onToolsListChanged(Function() handler) =>
      inner.onToolsListChanged(handler);

  @override
  void onResourcesListChanged(Function() handler) =>
      inner.onResourcesListChanged(handler);

  @override
  void onPromptsListChanged(Function() handler) =>
      inner.onPromptsListChanged(handler);

  @override
  void onRootsListChanged(Function() handler) =>
      inner.onRootsListChanged(handler);

  @override
  void onResourceUpdated(Function(String) handler) =>
      inner.onResourceUpdated(handler);

  @override
  void onResourceContentUpdated(
    Function(String uri, ResourceContents content) handler,
  ) => inner.onResourceContentUpdated(handler);

  @override
  void onProgress(
    Function(String progressToken, double progress, String message) handler,
  ) => inner.onProgress(handler);

  @override
  void onProgressNotification(
    void Function(ProgressNotificationParams progress) handler,
  ) => inner.onProgressNotification(handler);

  @override
  void onLogging(
    Function(McpLogLevel, String, String?, Map<String, dynamic>?) handler,
  ) => inner.onLogging(handler);

  @override
  void disconnect() => inner.disconnect();

  @override
  void startKeepAlive(
    Duration interval, {
    Duration timeout = const Duration(seconds: 10),
    int maxMissed = 1,
  }) => inner.startKeepAlive(interval, timeout: timeout, maxMissed: maxMissed);

  @override
  void stopKeepAlive() => inner.stopKeepAlive();

  @override
  void dispose() => inner.dispose();

  @override
  Stream<String> get onElicitationComplete => inner.onElicitationComplete;

  @override
  bool get cacheResults => inner.cacheResults;

  @override
  set cacheResults(bool value) => inner.cacheResults = value;

  @override
  void clearResultCache() => inner.clearResultCache();

  @override
  Future<Subscription> listen(SubscriptionFilter filter) =>
      inner.listen(filter);
}
