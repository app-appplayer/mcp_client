import 'package:logger/logger.dart';
import 'package:universal_io/io.dart';
import 'dart:convert';
import 'package:mcp_client/mcp_client.dart';

/// MCP 클라이언트 예제 애플리케이션
void main() async {
  final Logger _logger = Logger();

  // 로그 파일 생성
  final logFile = File('mcp_client_example.log');
  final logSink = logFile.openWrite();

  logToConsoleAndFile('MCP 클라이언트 예제 시작...', _logger, logSink);

  try {
    // 클라이언트 생성
    final client = McpClient.createClient(
      name: 'Example MCP Client',
      version: '1.0.0',
      capabilities: ClientCapabilities(
        roots: true,
        rootsListChanged: true,
        sampling: true,
      ),
    );

    logToConsoleAndFile('클라이언트가 초기화되었습니다.', _logger, logSink);

    // 파일 시스템 MCP 서버와 STDIO로 연결
    logToConsoleAndFile('MCP 파일 시스템 서버에 연결 중...', _logger, logSink);

    final transport = await McpClient.createStdioTransport(
      command: 'npx',
      arguments: ['-y', '@modelcontextprotocol/server-filesystem', Directory.current.path],
    );

    logToConsoleAndFile('STDIO 전송 메커니즘이 생성되었습니다.', _logger, logSink);

    // 연결 설정
    await client.connect(transport);
    logToConsoleAndFile('서버에 성공적으로 연결되었습니다!', _logger, logSink);

    // 알림 핸들러 등록
    client.onToolsListChanged(() {
      logToConsoleAndFile('도구 목록이 변경되었습니다!', _logger, logSink);
    });

    client.onResourcesListChanged(() {
      logToConsoleAndFile('리소스 목록이 변경되었습니다!', _logger, logSink);
    });

    client.onResourceUpdated((uri) {
      logToConsoleAndFile('리소스가 업데이트되었습니다: $uri', _logger, logSink);
    });

    client.onLogging((level, message, logger, data) {
      logToConsoleAndFile('서버 로그 [$level]: $message', _logger, logSink);
    });

    try {
      // 서버 건강 상태 확인
      final health = await client.healthCheck();
      logToConsoleAndFile('\n--- 서버 건강 상태 ---', _logger, logSink);
      logToConsoleAndFile('서버 실행 중: ${health.isRunning}', _logger, logSink);
      logToConsoleAndFile('연결된 세션 수: ${health.connectedSessions}', _logger, logSink);
      logToConsoleAndFile('등록된 도구 수: ${health.registeredTools}', _logger, logSink);
      logToConsoleAndFile('등록된 리소스 수: ${health.registeredResources}', _logger, logSink);
      logToConsoleAndFile('등록된 프롬프트 수: ${health.registeredPrompts}', _logger, logSink);
      logToConsoleAndFile('서버 가동 시간: ${health.uptime.inSeconds}초', _logger, logSink);
    } catch (e) {
      logToConsoleAndFile('서버 건강 상태 확인 기능이 지원되지 않습니다: $e', _logger, logSink);
    }

    // 도구 목록 확인
    final tools = await client.listTools();
    logToConsoleAndFile('\n--- 사용 가능한 도구 목록 ---', _logger, logSink);

    if (tools.isEmpty) {
      logToConsoleAndFile('사용 가능한 도구가 없습니다.', _logger, logSink);
    } else {
      for (final tool in tools) {
        logToConsoleAndFile('도구: ${tool.name} - ${tool.description}', _logger, logSink);
      }
    }

    // 현재 디렉토리 조회
    if (tools.any((tool) => tool.name == 'readdir')) {
      logToConsoleAndFile('\n--- 현재 디렉토리 내용 조회 ---', _logger, logSink);

      final result = await client.callTool('readdir', {
        'path': Directory.current.path
      });

      if (result.isError == true) {
        logToConsoleAndFile('오류: ${(result.content.first as TextContent).text}', _logger, logSink);
      } else {
        final contentText = (result.content.first as TextContent).text;
        logToConsoleAndFile('현재 디렉토리 내용:', _logger, logSink);

        List<String> files = [];
        try {
          // JSON 형식으로 반환된 파일 목록 파싱
          final List<dynamic> jsonList = jsonDecode(contentText);
          files = jsonList.cast<String>();
        } catch (e) {
          // 단순 텍스트 형식인 경우 줄바꿈으로 분리
          files = contentText.split('\n')
              .where((line) => line.trim().isNotEmpty)
              .toList();
        }

        for (final file in files) {
          logToConsoleAndFile('- $file', _logger, logSink);
        }

        // README.md 파일이 있으면 내용 읽기
        final readmeFile = files.firstWhere(
              (file) => file.toLowerCase() == 'readme.md',
          orElse: () => '',
        );

        if (readmeFile.isNotEmpty && tools.any((tool) => tool.name == 'readFile')) {
          logToConsoleAndFile('\n--- README.md 파일 읽기 ---', _logger, logSink);

          final readResult = await client.callTool('readFile', {
            'path': '${Directory.current.path}/$readmeFile'
          });

          if (readResult.isError == true) {
            logToConsoleAndFile('오류: ${(readResult.content.first as TextContent).text}', _logger, logSink);
          } else {
            final content = (readResult.content.first as TextContent).text;

            // 내용이 너무 길 경우 일부만 표시
            if (content.length > 500) {
              logToConsoleAndFile('${content.substring(0, 500)}...\n(내용이 너무 길어 일부만 표시)', _logger, logSink);
            } else {
              logToConsoleAndFile(content, _logger, logSink);
            }
          }
        }
      }
    }

    try {
      // 리소스 목록 확인
      final resources = await client.listResources();
      logToConsoleAndFile('\n--- 사용 가능한 리소스 목록 ---', _logger, logSink);

      if (resources.isEmpty) {
        logToConsoleAndFile('사용 가능한 리소스가 없습니다.', _logger, logSink);
      } else {
        for (final resource in resources) {
          logToConsoleAndFile(
              '리소스: ${resource.name} (${resource.uri})', _logger, logSink);
        }

        // 파일 시스템 리소스가 있으면 README.md 파일 읽기
        final readmeFile = 'README.md';
        if (await File(readmeFile).exists() &&
            resources.any((resource) => resource.uri.startsWith('file:'))) {
          logToConsoleAndFile(
              '\n--- 리소스로 README.md 파일 읽기 ---', _logger, logSink);

          try {
            final fullPath = '${Directory.current.path}/$readmeFile';
            final resourceResult = await client.readResource(
                'file://$fullPath');

            if (resourceResult.contents.isEmpty) {
              logToConsoleAndFile('리소스에 내용이 없습니다.', _logger, logSink);
            } else {
              final content = resourceResult.contents.first.text ?? '';

              // 내용이 너무 길 경우 일부만 표시
              if (content.length > 500) {
                logToConsoleAndFile(
                    '${content.substring(0, 500)}...\n(내용이 너무 길어 일부만 표시)',
                    _logger, logSink);
              } else {
                logToConsoleAndFile(content, _logger, logSink);
              }
            }
          } catch (e) {
            logToConsoleAndFile('리소스로 파일 읽기 오류: $e', _logger, logSink);
          }
        }
      }
    } catch (e) {
      logToConsoleAndFile('리소스 목록 확인 기능이 지원되지 않습니다: $e', _logger, logSink);
    }

    // 잠시 대기 후 종료
    await Future.delayed(Duration(seconds: 2));
    logToConsoleAndFile('\n예제 실행을 완료했습니다.', _logger, logSink);

    // 클라이언트 연결 종료
    client.disconnect();
    logToConsoleAndFile('클라이언트 연결이 종료되었습니다.', _logger, logSink);

  } catch (e, stackTrace) {
    logToConsoleAndFile('오류: $e', _logger, logSink);
    logToConsoleAndFile('스택 트레이스: $stackTrace', _logger, logSink);
  } finally {
    // 로그 파일 닫기
    await logSink.flush();
    await logSink.close();
  }
}

/// 콘솔과 파일에 동시에 로그 기록
void logToConsoleAndFile(String message, Logger logger, IOSink logSink) {
  // 콘솔에 로그 출력
  logger.d(message);

  // 파일에도 로그 기록
  logSink.writeln(message);
}