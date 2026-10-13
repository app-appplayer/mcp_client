/// McpOAuth rules not covered end to end (mcp_server/test/oauth_end_to_end_test.dart):
/// the 2025-03-26 fallback, RFC 9207 validation, resource metadata that
/// describes another server, option checks, and a changed authorization server.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  test('2025-03-26 server (no resource metadata, no AS metadata): default endpoints at the origin', () async {
    final seen = <String>[];
    final oauth = McpOAuth(
      McpOAuthOptions(redirectUri: 'http://localhost:9/cb'),
      httpClient: MockClient((r) async {
        seen.add('${r.method} ${r.url}');
        if (r.url.path == '/register') return _json({'client_id': 'legacy'}, 201);
        return http.Response('', 404);
      }),
    );
    final started = await oauth.begin(serverUrl: 'https://mcp.example.com/v1/mcp');
    expect(started.url.toString(), startsWith('https://mcp.example.com/authorize?'));
    expect(started.url.queryParameters['resource'], 'https://mcp.example.com/v1/mcp');
    expect(started.pending.tokenEndpoint, 'https://mcp.example.com/token');
    expect(seen, containsAllInOrder([
      'GET https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp',
      'GET https://mcp.example.com/.well-known/oauth-protected-resource',
      'GET https://mcp.example.com/.well-known/oauth-authorization-server',
      'POST https://mcp.example.com/register',
    ]));
  });

  test('RFC 9207: compare a present iss exactly; require it only when advertised', () {
    void check(bool supported, String? iss) =>
        checkAuthorizationResponseIssuer(recordedIssuer: 'https://as.example', issParameterSupported: supported, iss: iss);
    check(true, 'https://as.example');
    check(false, 'https://as.example');
    check(false, null);
    expect(() => check(true, null), throwsA(isA<OAuthError>()));
    expect(() => check(false, 'https://evil.example'), throwsA(isA<OAuthError>()));
    // No normalization: case, trailing slash and default port all differ.
    for (final variant in ['https://AS.example', 'https://as.example/', 'https://as.example:443']) {
      expect(() => check(true, variant), throwsA(isA<OAuthError>()), reason: variant);
    }
  });

  test('resource metadata describing another server is refused', () async {
    final oauth = McpOAuth(
      McpOAuthOptions(redirectUri: 'http://localhost:9/cb'),
      httpClient: MockClient((r) async => r.url.path.startsWith('/.well-known/oauth-protected-resource')
          ? _json({'resource': 'https://other.example/mcp', 'authorization_servers': ['https://as.example']})
          : http.Response('', 404)),
    );
    await expectLater(oauth.begin(serverUrl: 'https://mcp.example.com/mcp'),
        throwsA(isA<OAuthError>().having((e) => e.error, 'error', 'invalid_resource')));
  });

  test('redirect URIs are https or localhost; metadata document URLs are https with a path', () {
    expect(() => McpOAuthOptions(redirectUri: 'http://app.example/cb'), throwsArgumentError);
    McpOAuthOptions(redirectUri: 'https://app.example/cb');
    McpOAuthOptions(redirectUri: 'http://127.0.0.1:4000/cb');
    expect(() => McpOAuthOptions(redirectUri: 'https://a/cb', clientIdMetadataUrl: 'https://client.example'),
        throwsArgumentError);
    expect(() => McpOAuthOptions(redirectUri: 'https://a/cb', clientIdMetadataUrl: 'http://client.example/c.json'),
        throwsArgumentError);
  });

  test('canonical resource: lower-case scheme and host, no trailing slash, no fragment', () {
    expect(canonicalResourceUri('HTTPS://MCP.Example.com/'), 'https://mcp.example.com');
    expect(canonicalResourceUri('https://mcp.example.com:8443/server/mcp/#x'), 'https://mcp.example.com:8443/server/mcp');
  });

  test('a token from a previous authorization server is dropped once the server names another', () async {
    final store = MemoryOAuthStore();
    await store.saveGrant(OAuthGrant(
      issuer: 'https://old-as.example',
      resource: 'https://mcp.example.com/mcp',
      tokenEndpoint: 'https://old-as.example/token',
      clientId: 'c',
      token: OAuthToken(accessToken: 'old', issuedAt: DateTime.now()),
      scopes: const [],
    ));
    final oauth = McpOAuth(
      McpOAuthOptions(redirectUri: 'http://localhost:9/cb', store: store,
          preRegistered: {'https://new-as.example': const OAuthClientRegistration(clientId: 'n')}),
      httpClient: MockClient((r) async {
        if (r.url.path == '/.well-known/oauth-protected-resource/mcp') {
          return _json({'resource': 'https://mcp.example.com/mcp', 'authorization_servers': ['https://new-as.example']});
        }
        if (r.url.host == 'new-as.example' && r.url.path == '/.well-known/oauth-authorization-server') {
          return _json({
            'issuer': 'https://new-as.example',
            'authorization_endpoint': 'https://new-as.example/authorize',
            'token_endpoint': 'https://new-as.example/token',
            'code_challenge_methods_supported': ['S256'],
          });
        }
        return http.Response('', 404);
      }),
    );
    expect(await oauth.accessToken('https://mcp.example.com/mcp'), 'old');
    final started = await oauth.begin(serverUrl: 'https://mcp.example.com/mcp');
    expect(started.url.queryParameters['client_id'], 'n');
    expect(await oauth.accessToken('https://mcp.example.com/mcp'), isNull);
  });

  test('authorization server endpoints must be https (loopback aside)', () async {
    final oauth = McpOAuth(
      McpOAuthOptions(redirectUri: 'http://localhost:9/cb'),
      httpClient: MockClient((r) async {
        if (r.url.path.startsWith('/.well-known/oauth-protected-resource')) {
          return _json({'resource': 'https://mcp.example.com/mcp', 'authorization_servers': ['https://as.example']});
        }
        if (r.url.path == '/.well-known/oauth-authorization-server') {
          return _json({
            'issuer': 'https://as.example',
            'authorization_endpoint': 'http://as.example/authorize',
            'token_endpoint': 'https://as.example/token',
            'code_challenge_methods_supported': ['S256'],
          });
        }
        return http.Response('', 404);
      }),
    );
    await expectLater(oauth.begin(serverUrl: 'https://mcp.example.com/mcp'),
        throwsA(isA<OAuthError>().having((e) => e.error, 'error', 'insecure_endpoint')));
  });
}
