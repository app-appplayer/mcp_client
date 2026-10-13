import 'dart:async';

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

void main() {
  group('MCP Client Tests - 2025-03-26 Protocol', () {
    late Client client;
    late MockTransport mockTransport;

    setUp(() {
      // Create client with McpClient factory
      final config = McpClient.simpleConfig(
        name: 'Test Client',
        version: '1.0.0',
        enableDebugLogging: false,
      );

      client = McpClient.createClient(config);

      // Create mock transport
      mockTransport = MockTransport();
    });

    tearDown(() {
      client.disconnect();
    });

    test('Client initializes with 2025-03-26 protocol', () async {
      // Setup mock response for initialization
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {
            'tools': {
              'listChanged': true,
              'cancellation': true,
              'progress': true,
            },
            'resources': {'listChanged': true, 'subscribe': true},
            'prompts': {'listChanged': true},
            'sampling': {},
          },
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Verify that initialization message was sent
      expect(
        mockTransport.sentMessages.length,
        2,
      ); // initialize + initialized notification

      final initMessage = mockTransport.sentMessages[0];
      expect(initMessage['method'], equals(McpProtocol.methodInitialize));
      expect(
        initMessage['params']['clientInfo']['name'],
        equals('Test Client'),
      );
      // Client always proposes the latest supported revision; server
      // negotiates down if needed. This assertion just verifies the client
      // sent SOME spec-listed version.
      expect(
        McpProtocol.supportedVersions,
        contains(initMessage['params']['protocolVersion']),
      );

      // Verify that server capabilities were received
      expect(client.serverCapabilities?.tools, isTrue);
      expect(client.serverCapabilities?.resources, isTrue);
      expect(client.serverCapabilities?.prompts, isTrue);
      // `sampling` is a client capability; a server does not advertise it.

      // Verify server info
      expect(client.serverInfo?['name'], equals('Mock Server'));
    });

    test('Client handles protocol version negotiation', () async {
      // Server responds with older protocol version
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2024_11_05,
          'serverInfo': {'name': 'Legacy Server', 'version': '0.9.0'},
          'capabilities': {'tools': {}, 'resources': {}},
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Client should accept older protocol version
      expect(client.isConnected, isTrue);
      expect(client.serverInfo?['name'], equals('Legacy Server'));
    });

    test('Client can list tools with enhanced features', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {
            'tools': {
              'listChanged': true,
              'cancellation': true,
              'progress': true,
            },
          },
        },
      });

      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 2,
        'result': {
          'tools': [
            {
              'name': 'calculator',
              'description': 'Perform basic calculations',
              'supportsProgress': true,
              'supportsCancellation': true,
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'operation': {'type': 'string'},
                  'a': {'type': 'number'},
                  'b': {'type': 'number'},
                },
                'required': ['operation', 'a', 'b'],
              },
            },
          ],
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // List tools
      final tools = await client.listTools();

      // Verify tools list request was sent
      expect(
        mockTransport.sentMessages.length,
        3,
      ); // initialize + initialized + listTools
      expect(
        mockTransport.sentMessages[2]['method'],
        equals(McpProtocol.methodListTools),
      );

      // Verify enhanced tool features
      expect(tools.length, equals(1));
      expect(tools[0].name, equals('calculator'));
      // Keys outside the schema the server sent are kept, not dropped.
      expect(tools[0].extra['supportsProgress'], isTrue);
      expect(tools[0].extra['supportsCancellation'], isTrue);
    });

    test('Client can call tool with progress tracking', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {
            'tools': {'progress': true},
          },
        },
      });

      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 2,
        'result': {
          'operationId': 'op-123',
          'content': [
            {'type': 'text', 'text': 'Processing...'},
          ],
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Call tool with tracking
      final tracking = await client.callToolWithTracking('long-running-tool', {
        'data': 'test',
      }, trackProgress: true);

      // Verify tool call request was sent
      expect(mockTransport.sentMessages.length, 3);
      expect(
        mockTransport.sentMessages[2]['method'],
        equals(McpProtocol.methodCallTool),
      );
      expect(mockTransport.sentMessages[2]['params']['trackProgress'], isTrue);

      // Verify operation ID was received
      expect(tracking.operationId, equals('op-123'));
      expect(tracking.result.content.length, equals(1));
    });

    test('Client handles enhanced Content types', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'tools': {}},
        },
      });

      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 2,
        'result': {
          'content': [
            {
              'type': 'text',
              'text': 'Hello',
              'annotations': {'priority': 'high', 'language': 'en'},
            },
            {
              'type': 'image',
              'data': 'base64data',
              'mimeType': 'image/png',
              'annotations': {'alt': 'Test image'},
            },
            {
              'type': 'resource',
              'resource': {
                'uri': 'file:///test.txt',
                'mimeType': 'text/plain',
                'text': 'Resource content',
              },
            },
          ],
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Call tool
      final result = await client.callTool('content-test', {});

      // Verify different content types
      expect(result.content.length, equals(3));

      // Text content with annotations
      final textContent = result.content[0] as TextContent;
      expect(textContent.text, equals('Hello'));
      expect(textContent.annotations?['priority'], equals('high'));

      // Image content
      final imageContent = result.content[1] as ImageContent;
      expect(imageContent.data, equals('base64data'));
      expect(imageContent.mimeType, equals('image/png'));
      expect(imageContent.annotations?['alt'], equals('Test image'));

      // Resource content
      final resourceContent = result.content[2] as EmbeddedResource;
      expect(resourceContent.resource.uri, equals('file:///test.txt'));
      expect(resourceContent.resource.text, equals('Resource content'));
    });

    test('Client cancels via spec notifications/cancelled (no id)',
        () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {
            'tools': {'cancellation': true},
          },
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Cancel an in-flight request via the spec notification.
      final call = client.listTools();
      final requestId = mockTransport.sentMessages.last['id'];
      client.notifyCancelled(requestId, reason: 'user aborted');
      await expectLater(call, throwsA(isA<McpError>()));

      // Verify cancellation NOTIFICATION was sent (no id, no result expected).
      final cancelMsg = mockTransport.sentMessages.last;
      expect(cancelMsg['method'], equals('notifications/cancelled'));
      expect(cancelMsg.containsKey('id'), isFalse,
          reason: 'cancellation is a notification, not a request');
      expect(cancelMsg['params']['requestId'], equals(requestId));
      expect(cancelMsg['params']['reason'], equals('user aborted'));
    });

    test('Client handles progress notifications', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {},
        },
      });

      // Prepare to listen for progress
      final progressReceived = Completer<ProgressNotificationParams>();
      client.onProgressNotification(progressReceived.complete);

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Send a spec-shaped progress notification (token, progress, message).
      mockTransport.sendMockNotification({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'method': McpProtocol.methodProgress,
        'params': {
          'progressToken': 'tok-123',
          'progress': 3,
          'total': 4,
          'message': '75% complete',
        },
      });

      final p = await progressReceived.future.timeout(const Duration(seconds: 1));
      expect(p.progressToken, 'tok-123');
      expect(p.progress, 3);
      expect(p.total, 4);
      expect(p.message, '75% complete');
    });

    test('Client handles resource subscriptions', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {
            'resources': {'subscribe': true},
          },
        },
      });

      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 2,
        'result': {},
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Subscribe to resource
      await client.subscribeResource('file:///test.txt');

      // Verify subscription request was sent
      expect(mockTransport.sentMessages.length, 3);
      expect(
        mockTransport.sentMessages[2]['method'],
        equals('resources/subscribe'),
      );
      expect(
        mockTransport.sentMessages[2]['params']['uri'],
        equals('file:///test.txt'),
      );
    });

    test('Client handles resource update notifications', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'resources': {}},
        },
      });

      // Prepare to listen for resource updates
      final updateReceived = Completer<bool>();
      String? receivedUri;
      ResourceContents? receivedContent;

      client.onResourceContentUpdated((uri, content) {
        receivedUri = uri;
        receivedContent = content;
        updateReceived.complete(true);
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Send mock resource update notification
      mockTransport.sendMockNotification({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'method': McpProtocol.methodResourceUpdated,
        'params': {
          'uri': 'file:///test.txt',
          'content': {
            'uri': 'file:///test.txt',
            'mimeType': 'text/plain',
            'text': 'Updated content',
          },
        },
      });

      // Verify update notification was received
      await updateReceived.future.timeout(const Duration(seconds: 1));
      expect(receivedUri, equals('file:///test.txt'));
      expect(receivedContent?.text, equals('Updated content'));
    });

    test('Client validates protocol errors', () async {
      // Setup mock error response
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'tools': {}},
        },
      });

      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 2,
        'error': {
          'code': McpProtocol.errorToolNotFound,
          'message': 'Tool not found: unknown-tool',
        },
      });

      // Connect to mock transport
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Call unknown tool and expect error
      try {
        await client.callTool('unknown-tool', {});
        fail('Should have thrown an exception');
      } catch (e) {
        expect(e, isA<McpError>());
        final mcpError = e as McpError;
        expect(mcpError.code, equals(McpProtocol.errorToolNotFound));
        expect(mcpError.message, contains('Tool not found'));
      }
    });

    test('Client handles server-initiated sampling/createMessage request',
        () async {
      // Answering sampling requires declaring the sampling capability.
      client = Client(
        name: 'Test Client',
        version: '1.0.0',
        capabilities: const ClientCapabilities(sampling: true),
      );
      // Setup mock initialize response
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_06_18,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'sampling': {}},
        },
      });

      CreateMessageRequestParams? receivedRequest;
      client.onSamplingRequest((request) async {
        receivedRequest = request;
        return CreateMessageResult(
          role: Role.assistant,
          content: [TextContent(text: 'Hello! How can I help you?')],
          model: 'test-model',
          stopReason: 'endTurn',
        );
      });

      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Server pushes a sampling/createMessage request to the client.
      mockTransport.simulateMessage({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 'srv-1',
        'method': 'sampling/createMessage',
        'params': {
          'messages': [
            {
              'role': 'user',
              'content': {'type': 'text', 'text': 'Hello'},
            },
          ],
          'maxTokens': 100,
          'systemPrompt': 'You are a helpful assistant',
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Client handler ran with the parsed request.
      expect(receivedRequest, isNotNull);
      expect(receivedRequest!.maxTokens, 100);
      expect(receivedRequest!.systemPrompt, 'You are a helpful assistant');

      // Client emitted a JSON-RPC response with the matching id.
      final responseMsg = mockTransport.sentMessages.firstWhere(
        (m) => m['id'] == 'srv-1',
        orElse: () => <String, dynamic>{},
      );
      expect(responseMsg.isNotEmpty, isTrue,
          reason: 'response for srv-1 should have been sent');
      expect(responseMsg['result']['role'], equals('assistant'));
      expect(responseMsg['result']['model'], equals('test-model'));
    });

    test('Unified transport configuration - basic SSE', () async {
      final transportConfig = TransportConfig.sse(
        serverUrl: 'http://localhost:3000/sse',
        headers: {'User-Agent': 'Test'},
      );

      // Verify it's the correct type and has expected properties
      expect(transportConfig, isA<SseTransportConfig>());
      final sseConfig = transportConfig as SseTransportConfig;
      expect(sseConfig.serverUrl, equals('http://localhost:3000/sse'));
      expect(sseConfig.headers?['User-Agent'], equals('Test'));
      expect(sseConfig.enableCompression, isFalse);
      expect(sseConfig.heartbeatInterval, isNull);
      expect(sseConfig.bearerToken, isNull);
    });

    test('Unified transport configuration - SSE with OAuth', () async {
      final transportConfig = TransportConfig.sse(
        serverUrl: 'https://api.example.com/sse',
        bearerToken: 'test-token',
        headers: {'User-Agent': 'Test'},
      );

      // Verify OAuth configuration
      expect(transportConfig, isA<SseTransportConfig>());
      final sseConfig = transportConfig as SseTransportConfig;
      expect(sseConfig.serverUrl, equals('https://api.example.com/sse'));
      expect(sseConfig.bearerToken, equals('test-token'));
      expect(sseConfig.headers?['User-Agent'], equals('Test'));
    });

    test('Unified transport configuration - SSE with compression', () async {
      final transportConfig = TransportConfig.sse(
        serverUrl: 'http://localhost:3000/sse',
        enableCompression: true,
        enableGzip: true,
        enableDeflate: true,
      );

      // Verify compression configuration
      expect(transportConfig, isA<SseTransportConfig>());
      final sseConfig = transportConfig as SseTransportConfig;
      expect(sseConfig.serverUrl, equals('http://localhost:3000/sse'));
      expect(sseConfig.enableCompression, isTrue);
      expect(sseConfig.enableGzip, isTrue);
      expect(sseConfig.enableDeflate, isTrue);
    });

    test('Unified transport configuration - SSE with heartbeat', () async {
      final transportConfig = TransportConfig.sse(
        serverUrl: 'http://localhost:3000/sse',
        heartbeatInterval: const Duration(seconds: 30),
        maxMissedHeartbeats: 3,
      );

      // Verify heartbeat configuration
      expect(transportConfig, isA<SseTransportConfig>());
      final sseConfig = transportConfig as SseTransportConfig;
      expect(sseConfig.serverUrl, equals('http://localhost:3000/sse'));
      expect(sseConfig.heartbeatInterval, equals(const Duration(seconds: 30)));
      expect(sseConfig.maxMissedHeartbeats, equals(3));
    });

    test('Unified transport configuration - HTTP with all features', () async {
      final oauth = McpOAuth(McpOAuthOptions(redirectUri: 'http://localhost:8765/callback'));

      final transportConfig = TransportConfig.streamableHttp(
        baseUrl: 'https://api.example.com',
        oauth: oauth,
        enableCompression: true,
        heartbeatInterval: const Duration(seconds: 60),
        useHttp2: true,
        maxConcurrentRequests: 20,
      );

      // Verify HTTP configuration with all features
      expect(transportConfig, isA<StreamableHttpTransportConfig>());
      final httpConfig = transportConfig as StreamableHttpTransportConfig;
      expect(httpConfig.baseUrl, equals('https://api.example.com'));
      expect(httpConfig.oauth, same(oauth));
      expect(httpConfig.enableCompression, isTrue);
      expect(httpConfig.heartbeatInterval, equals(const Duration(seconds: 60)));
      expect(httpConfig.useHttp2, isTrue);
      expect(httpConfig.maxConcurrentRequests, equals(20));
    });

    test('Transport feature priority - OAuth takes precedence', () async {
      final transportConfig = TransportConfig.sse(
        serverUrl: 'https://api.example.com/sse',
        bearerToken: 'test-token', // OAuth feature
        enableCompression: true, // Compression feature
        heartbeatInterval: const Duration(seconds: 30), // Heartbeat feature
      );

      // Verify all features are stored correctly
      expect(transportConfig, isA<SseTransportConfig>());
      final sseConfig = transportConfig as SseTransportConfig;
      expect(sseConfig.bearerToken, equals('test-token'));
      expect(sseConfig.enableCompression, isTrue);
      expect(sseConfig.heartbeatInterval, equals(const Duration(seconds: 30)));

      // createAndConnect opens SseClientTransport with the token as an
      // Authorization header and starts ping keep-alive at the interval
      // (test/sse_config_and_keepalive_test.dart).
    });

    test('Client event streams work correctly', () async {
      // Setup event listeners
      final connectEvents = <ServerInfo>[];
      final disconnectEvents = <DisconnectReason>[];
      final errorEvents = <McpError>[];

      client.onConnect.listen(connectEvents.add);
      client.onDisconnect.listen(disconnectEvents.add);
      client.onError.listen(errorEvents.add);

      // Setup mock response
      mockTransport.queueResponse({
        'jsonrpc': McpProtocol.jsonRpcVersion,
        'id': 1,
        'result': {
          'protocolVersion': McpProtocol.v2025_03_26,
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {},
        },
      });

      // Connect
      await client.connect(mockTransport, era: ProtocolEra.legacy);

      // Wait for async events to propagate
      await Future.delayed(const Duration(milliseconds: 10));

      // Verify connect event
      expect(connectEvents.length, equals(1));
      expect(connectEvents[0].name, equals('Mock Server'));
      // Negotiated version is whatever the mock server advertised
      // (test default = v2025_03_26 in this fixture, but the assertion
      // is just that the field was populated).
      expect(client.negotiatedProtocolVersion, isNotEmpty);

      // Disconnect
      client.disconnect();

      // Wait for async events to propagate
      await Future.delayed(const Duration(milliseconds: 10));

      // Verify disconnect event
      expect(disconnectEvents.length, equals(1));
      expect(disconnectEvents[0], equals(DisconnectReason.clientDisconnected));
    });
  });
}
