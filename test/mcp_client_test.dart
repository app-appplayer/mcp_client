import 'dart:async';
import 'dart:convert';

import 'package:mcp_client/logger.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mcp_client/src/client/client.dart';
import 'package:mcp_client/src/models/models.dart';
import 'package:test/test.dart';

import 'mock_transport.dart';

void main() {
  group('MCP Client Tests', () {
    late Client client;
    late MockTransport mockTransport;

    setUp(() {
      // Use a lower log level for tests to avoid cluttering test output
      Logger.currentLevel = LogLevel.error;

      // Create client with default capabilities
      client = McpClient.createClient(
        name: 'Test Client',
        version: '1.0.0',
        capabilities: ClientCapabilities(
          roots: true,
          rootsListChanged: true,
          sampling: true,
        ),
      );

      // Create mock transport
      mockTransport = MockTransport();
    });

    tearDown(() {
      client.disconnect();
    });

    test('Client initializes correctly', () async {
      // Setup mock response for initialization
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {
            'name': 'Mock Server',
            'version': '1.0.0',
          },
          'capabilities': {
            'tools': {
              'listChanged': true
            },
            'resources': {
              'listChanged': true
            },
            'prompts': {
              'listChanged': true
            }
          }
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Verify that initialization message was sent
      expect(mockTransport.sentMessages.length, 2); // initialize + initialized notification

      final initMessage = mockTransport.sentMessages[0];
      expect(initMessage['method'], equals('initialize'));
      expect(initMessage['params']['clientInfo']['name'], equals('Test Client'));

      // Verify that server capabilities were received
      expect(client.serverCapabilities?.tools, isTrue);
      expect(client.serverCapabilities?.resources, isTrue);
      expect(client.serverCapabilities?.prompts, isTrue);

      // Verify server info
      expect(client.serverInfo?['name'], equals('Mock Server'));
    });

    test('Client can list tools', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'tools': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'tools': [
            {
              'name': 'calculator',
              'description': 'Perform basic calculations',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'operation': {'type': 'string'},
                  'a': {'type': 'number'},
                  'b': {'type': 'number'}
                }
              }
            }
          ]
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // List tools
      final tools = await client.listTools();

      // Verify tools list request was sent
      expect(mockTransport.sentMessages.length, 3); // initialize + initialized + listTools
      expect(mockTransport.sentMessages[2]['method'], equals('tools/list'));

      // Verify tools were received
      expect(tools.length, equals(1));
      expect(tools[0].name, equals('calculator'));
      expect(tools[0].description, equals('Perform basic calculations'));
    });

    test('Client can call a tool', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'tools': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'content': [
            {
              'type': 'text',
              'text': '8'
            }
          ]
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Call tool
      final result = await client.callTool('calculator', {
        'operation': 'add',
        'a': 5,
        'b': 3
      });

      // Verify tool call request was sent
      expect(mockTransport.sentMessages.length, 3); // initialize + initialized + callTool
      expect(mockTransport.sentMessages[2]['method'], equals('tools/call'));
      expect(mockTransport.sentMessages[2]['params']['name'], equals('calculator'));
      expect(mockTransport.sentMessages[2]['params']['arguments']['operation'], equals('add'));

      // Verify result
      expect(result.content.length, equals(1));
      expect(result.content[0], isA<TextContent>());
      expect((result.content[0] as TextContent).text, equals('8'));
    });

    test('Client handles tool errors', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'tools': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'content': [
            {
              'type': 'text',
              'text': 'Division by zero error'
            }
          ],
          'is_error': true
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Call tool
      final result = await client.callTool('calculator', {
        'operation': 'divide',
        'a': 5,
        'b': 0
      });

      // Verify error result
      expect(result.isError, isTrue);
      expect(result.content.length, equals(1));
      expect((result.content[0] as TextContent).text, equals('Division by zero error'));
    });

    test('Client can list resources', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'resources': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'resources': [
            {
              'uri': 'file:///test.txt',
              'name': 'Test File',
              'description': 'A test file',
              'mime_type': 'text/plain'
            }
          ]
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // List resources
      final resources = await client.listResources();

      // Verify resources list request was sent
      expect(mockTransport.sentMessages.length, 3); // initialize + initialized + listResources
      expect(mockTransport.sentMessages[2]['method'], equals('resources/list'));

      // Verify resources were received
      expect(resources.length, equals(1));
      expect(resources[0].uri, equals('file:///test.txt'));
      expect(resources[0].name, equals('Test File'));
      expect(resources[0].mimeType, equals('text/plain'));
    });

    test('Client can read resources', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'resources': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'contents': [
            {
              'uri': 'file:///test.txt',
              'mime_type': 'text/plain',
              'text': 'Hello, world!'
            }
          ]
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Read resource
      final result = await client.readResource('file:///test.txt');

      // Verify resource read request was sent
      expect(mockTransport.sentMessages.length, 3); // initialize + initialized + readResource
      expect(mockTransport.sentMessages[2]['method'], equals('resources/read'));
      expect(mockTransport.sentMessages[2]['params']['uri'], equals('file:///test.txt'));

      // Verify resource content was received
      expect(result.contents.length, equals(1));
      expect(result.contents[0].uri, equals('file:///test.txt'));
      expect(result.contents[0].mimeType, equals('text/plain'));
      expect(result.contents[0].text, equals('Hello, world!'));
    });

    test('Client can list prompts', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'prompts': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'prompts': [
            {
              'name': 'greeting',
              'description': 'Generate a greeting',
              'arguments': [
                {
                  'name': 'name',
                  'description': 'Name to greet',
                  'required': true
                }
              ]
            }
          ]
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // List prompts
      final prompts = await client.listPrompts();

      // Verify prompts list request was sent
      expect(mockTransport.sentMessages.length, 3); // initialize + initialized + listPrompts
      expect(mockTransport.sentMessages[2]['method'], equals('prompts/list'));

      // Verify prompts were received
      expect(prompts.length, equals(1));
      expect(prompts[0].name, equals('greeting'));
      expect(prompts[0].arguments.length, equals(1));
      expect(prompts[0].arguments[0].name, equals('name'));
      expect(prompts[0].arguments[0].required, isTrue);
    });

    test('Client can get prompts', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'prompts': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'result': {
          'description': 'A friendly greeting',
          'messages': [
            {
              'role': 'user',
              'content': {
                'type': 'text',
                'text': 'Hello, John!'
              }
            }
          ]
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Get prompt
      final result = await client.getPrompt('greeting', {'name': 'John'});

      // Verify prompt get request was sent
      expect(mockTransport.sentMessages.length, 3); // initialize + initialized + getPrompt
      expect(mockTransport.sentMessages[2]['method'], equals('prompts/get'));
      expect(mockTransport.sentMessages[2]['params']['name'], equals('greeting'));
      expect(mockTransport.sentMessages[2]['params']['arguments']['name'], equals('John'));

      // Verify prompt result was received
      expect(result.description, equals('A friendly greeting'));
      expect(result.messages.length, equals(1));
      expect(result.messages[0].role, equals('user'));
      expect((result.messages[0].content as TextContent).text, equals('Hello, John!'));
    });

    test('Client handles notifications correctly', () async {
      // Setup mock responses
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {
            'tools': {'listChanged': true},
            'resources': {'listChanged': true},
            'prompts': {'listChanged': true}
          }
        }
      });

      // Prepare to listen for notifications
      final toolsChanged = Completer<void>();
      final resourcesChanged = Completer<void>();
      final promptsChanged = Completer<void>();
      final loggingReceived = Completer<void>();

      client.onToolsListChanged(() {
        toolsChanged.complete();
      });

      client.onResourcesListChanged(() {
        resourcesChanged.complete();
      });

      client.onPromptsListChanged(() {
        promptsChanged.complete();
      });

      client.onLogging((level, message, logger, data) {
        expect(level, equals(McpLogLevel.info));
        expect(message, equals('Test log message'));
        loggingReceived.complete();
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Send mock notifications
      mockTransport.sendMockNotification({
        'jsonrpc': '2.0',
        'method': 'notifications/tools/list_changed',
        'params': {}
      });

      mockTransport.sendMockNotification({
        'jsonrpc': '2.0',
        'method': 'notifications/resources/list_changed',
        'params': {}
      });

      mockTransport.sendMockNotification({
        'jsonrpc': '2.0',
        'method': 'notifications/prompts/list_changed',
        'params': {}
      });

      mockTransport.sendMockNotification({
        'jsonrpc': '2.0',
        'method': 'logging',
        'params': {
          'level': McpLogLevel.info.index,
          'message': 'Test log message'
        }
      });

      // Verify notifications were received
      await toolsChanged.future.timeout(Duration(seconds: 1));
      await resourcesChanged.future.timeout(Duration(seconds: 1));
      await promptsChanged.future.timeout(Duration(seconds: 1));
      await loggingReceived.future.timeout(Duration(seconds: 1));
    });

    test('Client handles errors correctly', () async {
      // Setup mock error response
      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 1,
        'result': {
          'protocolVersion': '2024-11-05',
          'serverInfo': {'name': 'Mock Server', 'version': '1.0.0'},
          'capabilities': {'tools': {'listChanged': true}}
        }
      });

      mockTransport.queueResponse({
        'jsonrpc': '2.0',
        'id': 2,
        'error': {
          'code': -32602,
          'message': 'Tool not found: unknown-tool'
        }
      });

      // Connect to mock transport
      await client.connect(mockTransport);

      // Call unknown tool and expect error
      try {
        await client.callTool('unknown-tool', {});
        fail('Should have thrown an exception');
      } catch (e) {
        expect(e, isA<McpError>());
        final mcpError = e as McpError;
        expect(mcpError.code, equals(-32602));
        expect(mcpError.message, equals('Tool not found: unknown-tool'));
      }
    });
  });
}