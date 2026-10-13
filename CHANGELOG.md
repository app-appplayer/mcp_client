## 3.0.0

**Breaking — see `MIGRATION-3.0.md`.**

- Every MCP revision, 2024-11-05 through 2026-07-28 (stateless), plus the
  2026-07-28 tasks extension.
- Protocol types generated from the specification schemas, shared with
  mcp_server and mcp_llm.
- Authorization: OAuth 2.1 with discovery, PKCE and Client ID Metadata
  Documents (`McpOAuth`).
- Transports: stdio, HTTP+SSE and Streamable HTTP with resumption; one
  configuration type for each.
- Sampling, elicitation and roots answered for the capabilities the client
  declares.
- Tasks: `callToolAsTask`, `getTask`, `taskResult`, `cancelTask`.
- `DelegatingClient`: extend it to wrap a client and override only what
  changes. `connect(statelessMode:)` stays as a deprecated form of `era:`;
  a class that implements `Client.connect` declares it too.

## 2.2.1

### Fixed
- `Client.connect` fails when the transport reports a wire error instead of
  waiting out the 30-second request timeout. Requests in flight are completed
  with that error rather than left pending. An unreachable endpoint now fails
  in milliseconds.

## [2.2.0] - 2026-07-31

### Added — headers that are fetched, not fixed

`StreamableHttpTransportConfig.headers` is set when the transport is built and spread onto every request unchanged. Anything that expires cannot live there: a host holding a short-lived attestation or session credential has no way to attach it, because by the time a request goes out the value it captured is stale.

`headersProvider` is asked on **every** outbound request — POST, the SSE GET stream, and the session-terminating DELETE — and receives `(url, method)` so one provider can serve several transports and decide per destination. `RequestHeadersProvider` and `reservedHeaderNames` are exported with the transport.

Three properties make it safe to hand to host code, including a page script:

- **It cannot break the exchange.** Names the protocol owns (`Content-Type`, `Accept`, `MCP-Session-Id`, `MCP-Protocol-Version`, `Mcp-Method`, `Mcp-Name`, `Last-Event-ID`) are dropped rather than honoured, matched case-insensitively. A supplied `MCP-Session-Id` would otherwise fail the exchange in a way that reads as the server's fault.
- **It cannot cost a request.** A provider that throws, or exceeds `headersProviderTimeout` (5s default), contributes nothing and the request goes without it. Failing the request instead would report a hook problem as an unreachable server. What the origin then says about the missing credential is the accurate answer, and it comes from the origin.
- **Its failure is visible.** `lastHeadersProviderError` records the last one, because "the origin refused us" and "we never attached what the origin wanted" look identical on the wire and send a debugger to different places.

Explicitly configured `headers` win over supplied ones: a host that set a value meant it, and the provider is the general case yielding to the specific one.

Additive — no existing name or signature changed, and a transport with no provider behaves exactly as before. Ten regressions assert against a real socket, since the header map is assembled inside the transport and a mocked client would only be checking our own arrangement. Both guards mutation-checked.

## [2.1.1] - 2026-07-29 - Platform-conditional transports + specification conformance

Two cuts. The transport split changes behavior only on platforms without
`dart:io` — the STDIO and legacy SSE implementations are the same code, moved to
the native branch of a conditional export. The conformance work adds methods and
makes the protocol revision selectable; it removes nothing.

### Added — methods the protocol defines that this client could not send

Found by running this client against the official reference server: the calls
simply did not exist on `Client`.

- `ping()` — and an inbound `ping` is now answered with an empty result. The
  server side already handled `ping`; the client neither sent nor answered one,
  so a server keepalive got `Method not found` back.
- `complete(ref, argument, {context})` for `completion/complete`.

### Changed — the protocol revision is chosen per client

`Client.protocolVersion` was `final`, fixed at build time. A client could not
speak a revision a peer offered, and could not be exercised against more than
one. It is now a constructor parameter, carried through `McpClientConfig`,
`McpClient.createClient` and `copyWith`, defaulting to this build's default
version.

### Added — required request headers on revision `2026-07-28`

The Streamable HTTP transport mirrors `Mcp-Method`, and for the operations that
name a target `Mcp-Name`, into headers on the stateless path, using the
specification's base64 sentinel when a value cannot be carried as plain ASCII.
The values are derived from the body, never assumed: a mirror that disagrees
with the body is a rejectable mismatch.

### Changed
- `ClientTransport` moved to `src/transport/client_transport.dart` so both
  platform branches implement one type. `src/transport/transport.dart` is now a
  barrel that resolves `StdioClientTransport` and `SseClientTransport` per
  platform.
- The auth / compressed / heartbeat SSE variants resolve through
  `src/transport/legacy_sse.dart` instead of being exported individually.
  `mcp_client.dart` exports the barrel; the class names it re-exports are
  unchanged.

### Fixed
- On platforms without `dart:io`, constructing a transport that requires it now
  fails with an explicit `McpError` naming the unsupported transport and
  pointing at `StreamableHttpClientTransport`, instead of surfacing an opaque
  platform error from deep inside the implementation. An unavailable capability
  is reported, never silently substituted.
- `example/mcp_client_example_2.dart` — non-English log strings replaced with
  English.

## [2.1.0] - 2026-07-19 - 2025-11-25 conformance + 2026-07-28 stateless core (dormant)

Additive, backward-compatible (all new fields optional/named; `==`/`hashCode`
unchanged; behavior changes are negotiated-version gated). No public API removed.

### Added — 2025-11-25 conformance
- `ResourceTemplate.icons` (was dropped on resource templates).
- Sampling tool-calling: `CreateMessageRequest.tools` / `toolChoice`
  (`SamplingToolChoice` builders) + `CreateMessageResult.toolCalls` (SEP-1577).
- Typed elicitation layer (`elicitation.dart`): `EnumSchema` (titled/untitled
  `enumNames`), single- and multi-select enums (SEP-1330), URL-mode elicitation
  (SEP-1036), primitive default values (SEP-1034); raw-map path preserved.
- `Implementation.description` on `ClientInfo` / `ServerInfo`.
- JSON Schema 2020-12 default dialect helper (SEP-1613).
- OAuth: PRM discovery (RFC 9728, `WwwAuthenticateChallenge.parse` +
  `discoverFrom401`), OIDC Discovery 1.0 (PR#797), Client ID Metadata Documents
  (SEP-991, `OAuthConfig.clientIdMetadataUrl`), incremental scope step-up (SEP-835).

### Deprecated
- `CallToolResult.isStreaming` — non-standard hint, honored nowhere. Standard
  streaming = enable via a tool (`tools/call`) + deliver via a reactive resource
  (`Client.listen`/`subscriptions/listen`, or legacy `subscribeResource`).
  Retained + serialized for backward compatibility; removed in 3.0.

### Added — 2026-07-28 stateless core (BUILD-DORMANT, opt-in via `connect(statelessMode: true)`, default off)
- `_meta` reverse-DNS keys (`McpRequestMeta`), `server/discover` (`Client.discover()`),
  Multi-Round-Trip (`InputRequiredResult`), `subscriptions/listen` (`Client.listen`),
  Extensions framework (`ClientCapabilities.extensions`), Tasks extension
  (`getTask` / `updateTask` / `cancelTask`), RFC 9207 `iss` validation.
- Inert until opted in — zero behavior change for existing consumers.

## [2.0.1] - 2026-07-13 - Spec-optional description parsing

### Fixed
- `Tool` / `Resource` / `ResourceTemplate` `.fromJson` no longer require
  `description` (optional per the MCP spec; missing → `''`). A server omitting
  it made `tools/list` / `resources/list` parsing throw a `Null` cast.

## [2.0.0] - 2026-04-30 - MCP spec compliance + 2025-11-25 alignment

Big-Bang spec normalization. Supports protocol revisions 2024-11-05, 2025-03-26, 2025-06-18, and 2025-11-25 with per-version capability gating. Pairs with mcp_server 2.0.

### Breaking
- **Sampling direction fixed.** `client.createMessage(...)` (which sent a request to the server) is removed. Sampling is server-initiated per spec — register a handler with `client.onSamplingRequest((req) async { ... })` so the host LLM fulfils it.
- **Roots direction fixed.** `client.listRoots()` (which sent a request to the server) is removed. The server requests roots from the client; configure them locally with `client.addRoot(...)` / `client.removeRoot(...)` and read via `client.roots`. Override the default response handler with `client.onListRoots(...)`. `roots/add` and `roots/remove` JSON-RPC methods (non-spec) are deleted.
- **Cancellation is now a notification.** `client.cancelOperation(opId)` (which sent a `cancel` request) is removed; use `client.notifyCancelled(requestId, reason: ...)` which emits the spec `notifications/cancelled` notification.
- **Logging method name corrected.** `setLoggingLevel` now sends `logging/setLevel` (camelCase) per spec — was `logging/set_level`.
- **`client.healthCheck()` removed** — `health/check` is non-spec; expose health via your transport (e.g. an HTTP `/health` endpoint).
- **`onSamplingResponse` listener removed** — the non-spec `sampling/response` notification path is gone, replaced by the standard request/response shape.

### Added
- `client.onSamplingRequest(handler)` — register a host LLM completion handler.
- `client.onElicitationRequest(handler)` — register a user-input handler (spec 2025-06-18 `elicitation/create`).
- `client.onListRoots(handler)` — override the default `roots/list` response.
- `client.notifyCancelled(requestId, {reason})` and `client.notifyProgress(token, progress, {total, message})` — spec notifications.
- `ClientCapabilities.elicitation` flag.
- `McpProtocol.v2025_06_18` and `McpProtocol.v2025_11_25` constants. `defaultVersion` advances to `v2025_11_25`.
- Per-version capability gates: `McpProtocol.supportsBatching` / `supportsElicitation` / `requiresProtocolHeader`.
- Schema: `Tool.title` / `Tool.outputSchema` / `Tool.icons` / `Tool.meta`. `CallToolResult.structuredContent`. `AudioContent`. `ResourceLinkContent`.
- Incoming-request infrastructure routes server-initiated requests to registered handlers and returns a JSON-RPC response with the matching id.

---

## [1.1.1] - 2026-04-28

### Changed
- README cleanup — removed "MCP Family" section, installation block, dev.to articles, and donation links.

---

## 1.1.0

* New Features
  * Deferred Tool Loading support (Progressive Tool Disclosure)
    * `ToolMetadata` - Lightweight tool representation (name + description only)
    * `ToolRegistry` - Cache layer for tool definitions with metadata extraction
    * `ClientToolMetadataExtension` - Extension for easy metadata access
    * Reduces token usage by 60-80% when sending tool definitions to LLMs
    * Zero breaking changes - fully backward compatible, opt-in only

## 1.0.2

* Bug Fixes
  * Added `terminateOnClose` parameter to StreamableHTTP transport configuration
    * Allows controlling whether DELETE request is sent on disconnect
    * Default value is `true` to maintain backward compatibility
    * Set to `false` to allow reconnection after disconnect without server session termination
  * Enhanced session validation and localStorage management
    * Server-side session validation through `hasSession()` check
    * Automatic localStorage cleanup when session ID changes (server restart detection)
    * Proper handling of invalid/expired session IDs
    * Improved reconnection logic for StreamableHTTP transport

## 1.0.1

* Bug Fixes
  * Fixed SSE endpoint parsing issue where endpoint data was incorrectly processed as null
  * Added support for SSE events without explicit event type field
  * Improved compatibility with various SSE server implementations
  * Fixed web platform SSE implementation to match native platform behavior

## 1.0.0

* Breaking Changes and Major Update to 2025-03-26 Protocol
  * Updated to MCP protocol version 2025-03-26 (from 2024-11-05)
  * Complete refactoring for modern Dart 3.8+ patterns
  * Added @immutable annotations throughout models
  * Introduced sealed classes and pattern matching
  * Enhanced type safety with Result<T, E> pattern
  * Backward API compatibility maintained

* New Features
  * Protocol version negotiation support
  * Enhanced Content model with annotations
  * Tool cancellation and progress tracking
  * Improved resource templates
  * Better error handling with typed results
  * Protocol constants centralized in McpProtocol class

* Technical Improvements
  * All models now use const constructors
  * Factory constructors for JSON deserialization
  * Centralized protocol configuration
  * Better numeric type handling in JSON
  * Cleaner API surface with protocol exports

## 0.1.8

* Added
  * Client event monitoring system using Dart's Stream API
    * `onConnect` stream for server connection events
    * `onDisconnect` stream for server disconnection events
    * `onError` stream for error events
  * New models to support event monitoring
    * `ServerInfo` class for connection details
    * `DisconnectReason` enum for disconnect causes
  * Client lifecycle management improvements
    * Added `dispose()` method for proper resource cleanup
    * Enhanced error propagation through dedicated stream
    * Better connection state tracking and reporting

## 0.1.7
## 0.1.6
## 0.1.5

* Bug Fixed

## 0.1.4

* Bug Fixes

## 0.1.3

* Fixed
  * SSE Transport Connection Issues: Fixed critical issue with Server-Sent Events (SSE) connection where the client could not properly process JSON-RPC responses from the server.
    * Improved event stream processing to correctly parse JSON-RPC messages
    * Fixed handling of the endpoint event to establish the message channel
    * Enhanced buffer management for fragmented SSE event data
  * JSON-RPC Message Flow: Corrected the bidirectional communication flow between client and server:
    * Client requests via HTTP POST to message endpoint now properly receive responses
    * Fixed timeout issues by correctly handling asynchronous SSE responses
* Improved
  * Error Handling: Enhanced error reporting and recovery for connection issues
  * Logging: Added more detailed diagnostic logging for easier troubleshooting
  * Stability: More robust message endpoint URL construction and session handling
* Technical Notes
  * Updated SseClientTransport implementation to maintain persistent connections
  * Fixed JSON response type handling for resource templates
  * Improved session management and reconnection logic

## 0.1.2

* New Features
  * Protocol Update: Full support for all features of the 2024-11-05 protocol specification
  * Progress Tracking: Added onProgress method to receive notifications about progress of long-running operations
  * Operation Cancellation: Added cancelOperation method to cancel running operations
  * Server Health Check: Added healthCheck method to check server's health status
  * Resource Template Enhancement: Added getResourceWithTemplate method to access resources using URI templates
  * Tool Execution with Progress Tracking: Added callToolWithTracking method that returns operation IDs
  * Enhanced Resource Update Notifications: Added onResourceContentUpdated method that includes content information
  * Sampling Response Handling: Added onSamplingResponse method to process sampling results
* New Model Classes
  * ServerHealth: Class to hold server health status information
  * PendingOperation: Class for managing ongoing operations
  * ProgressUpdate: Class for operation progress updates
  * CachedResource: Class for resource caching
  * ToolCallTracking: Class to return tool call results and operation IDs together
* Technical Improvements
  * Enhanced protocol version validation
  * Improved error handling and exception messages
  * Added options to colorize logs and include timestamps for easier debugging

## 0.1.1

* Bug fixes

## 0.1.0

* Initial release
* Created Model Context Protocol (MCP) client implementation for Dart
* Features:
  * Connect to MCP servers with standardized protocol support
  * Access data through Resources
  * Execute functionality through Tools
  * Utilize interaction patterns through Prompts
  * Support for Roots management
  * Support for Sampling (LLM text generation)
    * Multiple transport layers:
    * Standard I/O for local process communication
  * Server-Sent Events (SSE) for HTTP-based communication
  * Platform support: Android, iOS, web, Linux, Windows, macOS