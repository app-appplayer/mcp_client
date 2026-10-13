# Moving to mcp_client 3.0

3.0 implements every MCP revision (2024-11-05 … 2026-07-28) in full and
shares its protocol types with mcp_server and mcp_llm. This guide lists
every change that can stop 2.x code from compiling or make it behave
differently.

## 1. Protocol types

The model classes are generated from the specification schemas
(`Tool`, `CallToolResult`, `TextContent`, `Resource`, `Prompt`,
`CreateMessageResult`, …). They keep every key a peer sends, including keys
of newer revisions, and read lazily: a missing required field or a value of
the wrong type is a `FormatException` when that field is read.

### 1.1 Names

| 2.x | 3.0 |
|---|---|
| `Icon`, `Icons`, `Notification` (protocol types) | `McpIcon`, `McpIcons`, `McpNotification` — so they do not shadow Flutter's |
| `MessageRole` | `Role` (`Role.user`, `Role.assistant`); there is no system role in MCP messages |
| `MCPContentType` | none: content classes are told apart by type (`TextContent`, `ImageContent`, `AudioContent`, `ResourceLink`, `EmbeddedResource`) |
| `CancelRequestNotification` | `CancelledNotification` (`CancelledNotificationParams(requestId:, reason:)`) |
| `LogMessageNotification` | `LoggingMessageNotification` |
| `ToolsListChangedNotification` / `ResourcesListChangedNotification` / `PromptsListChangedNotification` | `ToolListChangedNotification` / `ResourceListChangedNotification` / `PromptListChangedNotification` |
| `CompletionRequest` | `CompleteRequest` |
| `SamplingToolChoice` | `ToolChoice(mode: ToolChoiceMode.auto)` (`.required`, `.none`) |
| `ClientInfo`, `ServerInfo` | still there, now names for the protocol's `Implementation` (`name`, `version`, `title`, `description`, `icons`, `websiteUrl`) |

Kept for 2.x code, as types and as constructors with their 2.x arguments
(deprecated where the protocol has a name of its own):

| 2.x name | Is |
|---|---|
| `Message(role: 'user', content: …)` | a `PromptMessage`; `role` may be a `Role` or its string |
| `ResourceContentInfo(uri:, text: / blob:)` | a `ResourceContents`; with neither `text` nor `blob`, `text` stays `null` |
| `ResourceContent(uri:, text:, blob:, mimeType:, annotations:)` | an `EmbeddedResource`, read through the 2.x members (`uri`, `text`, `blob`, `mimeType`, `annotations` as a map); `fromJson` also reads the 2.x flat form |
| `Content`, `ResourceLinkContent`, `CompletionResult` | `ContentBlock`, `ResourceLink`, `CompleteResult` |
| `ImageContent.fromBase64(data:, mimeType:)` | the constructor |
| `TaskStatus.wire`, `TaskStatus.fromWire(s)`, `Task.isTerminal` | `value`, `TaskStatus.of(s)` (which keeps unknown values), `status.isTerminal` |

### 1.2 Requests and notifications carry `params`

A request or notification type is the whole JSON-RPC message
(`{method, params}`); its fields moved to the `…Params` type:

| 2.x | 3.0 |
|---|---|
| `CallToolRequest(name:, arguments:)`, `request.name` | `CallToolRequestParams(name:, arguments:)`; `request.params.name` |
| `GetPromptRequest`, `ReadResourceRequest`, `InitializeRequest` | `GetPromptRequestParams`, `ReadResourceRequestParams`, `InitializeRequestParams` |
| `CreateMessageRequest(messages:, maxTokens:, …)` | `CreateMessageRequestParams(…)` |
| `ProgressNotification(progress:, total:)` | `ProgressNotificationParams(progressToken:, progress:, total:, message:)` |
| `ResourceUpdatedNotification(uri:)` | `ResourceUpdatedNotificationParams(uri:)` |

### 1.3 Fields the protocol does not have

Removed: `CallToolResult.isStreaming`, `CreateMessageResult.toolCalls` /
`hasToolCalls` (tool use is `ToolUseContent` in `content`), `ModelHint.weight`,
`Tool.metadata` / `supportsProgress` / `supportsCancellation`,
`Prompt.metadata`, `Resource.metadata`, `PromptArgument.defaultValue`,
`ImageContent.url`, `Root.description`, `ServerCapabilities.sampling`,
`ClientInfo` / `ServerInfo` `capabilities` / `metadata` /
`protocolVersion`, `Task.result` / `error` / `inputRequests` (they are on
the extension's `DetailedTask` kinds and on `GetTaskResult`). A peer that
still sends one keeps it: `tool['metadata']`.

### 1.4 Types that follow the schema

| 2.x | 3.0 |
|---|---|
| `const [TextContent(text: 'x')]` | `[TextContent(text: 'x')]` — constructors are not `const` |
| `tool.description`, `prompt.description`, `resource.description` / `mimeType`, `resourceTemplate.description`, `root.name`, `promptArgument.required`, `prompt.arguments`, `modelHint.name` | nullable — optional in the specification (`tool.description ?? ''`) |
| `CreateMessageResult(role: 'assistant', content: TextContent(…))` | `CreateMessageResult(role: Role.assistant, content: [TextContent(…)])` |
| `role`, `status`, `action`, `level` as strings | enumeration classes (`Role`, `TaskStatus`, `ElicitResultAction`, `LoggingLevel`) |
| `annotations` as `Map` | `Annotations` (`Annotations.fromJson(map)`) |
| `icons` as `List<Map>` | `List<McpIcon>` |
| `structuredContent` as `Map` | `Object?` (any JSON value) |
| `ModelPreferences` priorities as `double` | `num` |
| `SubscriptionFilter` flags as `bool` | `bool?` |
| `CallToolResult([…])` (positional) | `CallToolResult(content: […])` |
| `ReadResourceResult.contents` as `List<ResourceContentInfo>` | `List<ResourceContents>`; `contents.first.text` still works |
| `InitializeResult.capabilities` as `Map` | `ServerCapabilities` |
| `DiscoverResult.serverInfo` | gone; `cacheScope` / `ttlMs` are required and typed |

**Comparisons that now compile but never match.** An enumeration is not
equal to its string: `message.role == 'user'` is always false — write
`message.role == Role.user` (or compare `.value`). The analyzer reports
these with the `unrelated_type_equality_checks` lint.

### 1.5 Typed elicitation

The 2.x typed layer (`ElicitationRequest`, `ElicitationResponse`,
`ElicitationAction`, `ElicitationMode`, `ElicitationFieldSchema`,
`StringElicitationField`, `NumberElicitationField`,
`BooleanElicitationField`, `EnumElicitationField`,
`MultiSelectEnumElicitationField`, `GenericElicitationField`, the 2.x
`EnumSchema`) is replaced by the protocol's types:

| 2.x | 3.0 |
|---|---|
| `onElicitationRequestTyped((ElicitationRequest r) async => ElicitationResponse.accept(…))` | `onElicitationRequestTyped((ElicitRequestParams r) async => ElicitResult(action: ElicitResultAction.accept, content: …))` |
| form / url mode | `r is ElicitRequestFormParams` (`requestedSchema`) / `r is ElicitRequestURLParams` (`url`, `elicitationId`) |
| field classes | `StringSchema`, `NumberSchema`, `BooleanSchema`, `UntitledSingleSelectEnumSchema`, `TitledSingleSelectEnumSchema`, `UntitledMultiSelectEnumSchema`, `TitledMultiSelectEnumSchema`, `LegacyTitledEnumSchema` |

### 1.6 Importing mcp_client and mcp_server together

Each package carries its own copy of the generated types, so a library that
imports both barrels sees two `Role`, `Tool`, … Import one with a prefix
(`import 'package:mcp_server/mcp_server.dart' as ms;`) or `hide` the names
you take from the other. Values cross by JSON:
`ms.Tool.fromJson(tool.toJson())`.

## 2. Client API

| 2.x | 3.0 |
|---|---|
| `connect(transport, statelessMode: …)` | still accepted (deprecated): `true` is `era: ProtocolEra.modern`, `false` is `era: ProtocolEra.legacy`. Without either, the default `ProtocolEra.auto` probes `server/discover` (waiting `eraProbeTimeout`: 30 s on stdio, 5 s elsewhere) and falls back to `initialize` |
| `connectWithRetry(transport, …)` | `connectWithRetry(() => openTransport(), …)` — a failed transport is closed, so each attempt needs a new one (a 2.x retry reused the closed one) |
| `onSamplingRequest((CreateMessageRequest r) …)` | `(CreateMessageRequestParams r) …` (`r.messages`, `r.maxTokens` as before) |
| `onResourceContentUpdated((uri, ResourceContentInfo c) …)` | `(uri, ResourceContents c) …` |
| `onProgress((requestId, progress, message) …)` | same shape; the first argument is the notification's `progressToken`, and `message` is `''` when absent (2.x read a `requestId` field no specification has and failed on a conforming server). `onProgressNotification((p) …)` gives the whole params |
| `getTask(id)` returns `Task` | returns `GetTaskResult` (the task's fields, `result` / `error` when finished) |
| `cancelTask(id)` returns `void` | returns `Task?` |
| `complete(…)` returns `CompletionResult` | `CompleteResult` (the same type under its protocol name) |
| `notifyCancelled(String id)` | `notifyCancelled(Object id)`; only for a request this client has in flight, otherwise `ArgumentError` |
| `onConnect` emits `ServerInfo` | emits `Implementation` (`ServerInfo` is its alias) |
| `ping()` | not on a 2026-07-28 connection (`McpError` -32601); `startKeepAlive` refuses it there |

Every request method takes `{Map<String, dynamic>? meta, RequestOptions?
options}` (`getPrompt` positionally): `RequestOptions(timeout:, onProgress:,
cancel:)`.

A class that **implements** `Client` (a test double, a wrapper) must add
those parameters and implement the public fields too: `eraProbeTimeout`
(`Duration?`), `validateToolOutput` and `cacheResults` (getters and
setters), `title`, `websiteUrl`, `icons`, `requestTimeout`,
`maxRequestTimeout`, `era`, `onElicitationComplete`. Delegating to an inner
`Client` covers them.

### Behaviour that changed

- **Server-initiated requests need the capability.** `sampling/createMessage`,
  `elicitation/create` and `roots/list` are answered only when declared in
  `ClientCapabilities` (`sampling: true`, `elicitation: true`, `roots:
  true`); registering a handler does not declare it (in 2.x it did not
  either, but undeclared requests were answered).
- `subscribeResource` / `unsubscribeResource` work on every revision; on
  2026-07-28 the client keeps one `subscriptions/listen` for the subscribed
  URIs.
- Tool output is checked against the tool's `outputSchema`
  (`validateToolOutput`, default on).

### A class that implements `Client`

A wrapper or a test double written as `implements Client` has to declare
every member `Client` has. Extend `DelegatingClient(inner)` instead and
override only the members that change; the rest reach `inner`, including
members later versions add.

A class that implements `connect` itself declares the deprecated
`statelessMode` parameter as well:
`Future<void> connect(ClientTransport transport, {ProtocolEra era = ProtocolEra.auto, bool? statelessMode})`.

## 3. Transports

| 2.x | 3.0 |
|---|---|
| `TransportConfig.sse` picked `SseAuthClientTransport` / `SseCompressedClientTransport` / `SseHeartbeatClientTransport` by option | always the standard HTTP+SSE transport: a token (`bearerToken` / `oauthToken`) goes in `Authorization` on the stream and every POST; `connectionTimeout` bounds opening |
| `heartbeatInterval` | `ping` every interval once connected (`Client.startKeepAlive`); `maxMissedHeartbeats` unanswered in a row end the connection. Also on Streamable HTTP; not on 2026-07-28 |
| `enableCompression`, `enableGzip`, `enableDeflate`, `compressionLevel`, `useHttp2` | deprecated, no effect: the HTTP client negotiates compression itself and speaks HTTP/1.1 |
| `SseAuthClientTransport`, `SseCompressedClientTransport`, `SseHeartbeatClientTransport` | deprecated: their event parsing is not the standard one, and the heartbeat one waits for events MCP servers do not send |
| `TransportConfig.sse(oauthConfig: …)` | removed (HTTP+SSE has no authorization flow) |

On the web, Streamable HTTP is the transport; stdio and HTTP+SSE need
`dart:io`.

## 4. Error codes

Codes this package reports for its own conditions moved out of the range the
specification assigns (-32020 … -32042). Compare with the constants:

| Condition | 2.x | 3.0 |
|---|---|---|
| authentication required (HTTP 401 / 403) | -32001 | `McpProtocol.errorAuthenticationRequired` (-31001) |
| session expired (HTTP 404) | — | `McpProtocol.errorSessionExpired` (-31002); the client starts a new session and retries once |
| network / stream lost | — | `McpProtocol.errorNetwork` (-31009) |
| resource not found | -32001 / -32002 mixed | `McpProtocol.errorResourceNotFound` (-32002); 2026-07-28 servers send -32602 — use `McpProtocol.isResourceNotFound(code, version)` |

## 5. Tasks

`callToolAsTask(name, args)` returns the created `Task`; `taskResult(id)`
waits for the outcome; `listTasksPage({cursor})`; `cancelTask(id)`.
Core (2025-11-25) and extension (2026-07-28) tasks use the same calls.

## 6. Authorization

- `StreamableHttpClientTransport.create(oauthConfig: …)` /
  `TransportConfig.streamableHttp(oauthConfig: …)` →
  `oauth: McpOAuth(McpOAuthOptions(...))`. A 401 starts discovery
  (Protected Resource Metadata → authorization server metadata),
  registration (pre-registered → Client ID Metadata Document → Dynamic
  Client Registration), the authorization code flow with PKCE, `state`,
  `resource` and the RFC 9207 `iss` check; the request is then retried. A
  403 `insufficient_scope` steps up.
- Interactive hosts give `McpOAuthOptions.authorize: (url) async =>
  redirectUri`. Browser hosts call `McpOAuth.begin(...)`, keep
  `PendingAuthorization.encode()` across the navigation, and call
  `McpOAuth.complete(PendingAuthorization.decode(saved)!, redirect)`.
- A server behind authorization refuses **every** HTTP request without a
  valid token, `initialize` included, so `connect` itself fails: with
  `oauth:` the client authorizes and retries; without it `connect` throws
  `McpError` with `McpProtocol.errorAuthenticationRequired` (the challenge in
  `data`). Treat that as "authorization needed", not as an unreachable
  server.
- Removed: `authenticateWithOAuth` (threw `UnimplementedError`),
  `setOAuthToken`, `OAuthTokenManager.storeEncryptedToken` /
  `loadEncryptedToken` / `loadPersistedTokens` / `storeToken(persistent:)`
  (they stored or encrypted nothing). Keep tokens across restarts with an
  `OAuthStore` over the platform's secure storage.
- `AuthServerMetadata.codeChallengeMethodsSupported` is `List<String>?`:
  absent means the server does not support PKCE, and the client refuses it.
- `HttpOAuthClient` remains for hosts that drive the steps themselves; it
  checks the metadata issuer, tries the path-specific well-known URLs first,
  and sends `resource`.
