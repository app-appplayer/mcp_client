/// Wire-behavior coverage for the 2025-11-25 Part-A AUTH stack (A5–A8):
/// A5 PRM discovery (RFC 9728 / SEP-985), A6 incremental scope step-up
/// (SEP-835), A7 OIDC Discovery 1.0 alongside RFC 8414 (PR#797), A8 CIMD
/// client_id-as-URL (SEP-991). Discovery is HTTP metadata FETCHES — exercised
/// with a MockClient (VM + dart2js). No crypto is re-implemented; the existing
/// PKCE/token flow is reused with the discovered endpoints.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  // --------------------------------------------------------------------------
  // A5/A6 — WWW-Authenticate parser (RFC 9728 / SEP-985 / SEP-835)
  // --------------------------------------------------------------------------
  group('A5/A6 WwwAuthenticateChallenge.parse', () {
    test('parses resource_metadata, error, and scope with a comma-in-URL', () {
      const header =
          'Bearer resource_metadata="https://api.example.com/.well-known/'
          'oauth-protected-resource", error="invalid_token", '
          'error_description="Invalid or missing Bearer token", '
          'scope="mcp:tools mcp:resources"';
      final c = WwwAuthenticateChallenge.parse(header)!;
      expect(c.isBearer, isTrue);
      expect(c.resourceMetadata,
          'https://api.example.com/.well-known/oauth-protected-resource');
      expect(c.error, 'invalid_token');
      expect(c.errorDescription, 'Invalid or missing Bearer token');
      expect(c.scope, 'mcp:tools mcp:resources');
      expect(c.scopes, ['mcp:tools', 'mcp:resources']);
    });

    test('null / empty header yields null', () {
      expect(WwwAuthenticateChallenge.parse(null), isNull);
      expect(WwwAuthenticateChallenge.parse('   '), isNull);
    });

    test('bare Bearer challenge parses with no params', () {
      final c = WwwAuthenticateChallenge.parse('Bearer')!;
      expect(c.isBearer, isTrue);
      expect(c.resourceMetadata, isNull);
      expect(c.scopes, isEmpty);
    });
  });

  // --------------------------------------------------------------------------
  // A5 — PRM discovery (fetch + well-known fallback)
  // --------------------------------------------------------------------------
  group('A5 Protected Resource Metadata discovery', () {
    OAuthConfig cfg() => const OAuthConfig(
          authorizationEndpoint: 'https://as.example.com/authorize',
          tokenEndpoint: 'https://as.example.com/token',
          clientId: 'client-1',
        );

    test('fetchProtectedResourceMetadata reads authorization_servers', () async {
      final mock = MockClient((req) async {
        expect(req.url.path, '/.well-known/oauth-protected-resource');
        return http.Response(
          jsonEncode({
            'resource': 'https://api.example.com',
            'authorization_servers': ['https://as.example.com'],
            'scopes_supported': ['mcp:tools'],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      final oauth = HttpOAuthClient(config: cfg(), httpClient: mock);
      final prm = await oauth.fetchProtectedResourceMetadata(
        Uri.parse(
            'https://api.example.com/.well-known/oauth-protected-resource'),
      );
      expect(prm.authorizationServers, ['https://as.example.com']);
      expect(prm.primaryAuthorizationServer, 'https://as.example.com');
      expect(prm.scopesSupported, ['mcp:tools']);
    });

    test('wellKnownProtectedResourceUrl derives the origin fallback', () {
      final oauth = HttpOAuthClient(config: cfg(), httpClient: MockClient((_) async => http.Response('', 404)));
      expect(
        oauth.wellKnownProtectedResourceUrl('https://api.example.com/mcp').toString(),
        'https://api.example.com/.well-known/oauth-protected-resource',
      );
    });
  });

  // --------------------------------------------------------------------------
  // A7 — AS discovery: OIDC alongside RFC 8414
  // --------------------------------------------------------------------------
  group('A7 authorization-server discovery (RFC 8414 + OIDC)', () {
    OAuthConfig cfg() => const OAuthConfig(
          authorizationEndpoint: 'https://as.example.com/authorize',
          tokenEndpoint: 'https://as.example.com/token',
          clientId: 'client-1',
        );

    test('uses RFC 8414 when present', () async {
      final mock = MockClient((req) async {
        if (req.url.path == '/.well-known/oauth-authorization-server') {
          return http.Response(
            jsonEncode({
              'issuer': 'https://as.example.com',
              'authorization_endpoint': 'https://as.example.com/rfc8414/auth',
              'token_endpoint': 'https://as.example.com/rfc8414/token',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
      final oauth = HttpOAuthClient(config: cfg(), httpClient: mock);
      final meta =
          await oauth.discoverAuthorizationServer('https://as.example.com');
      expect(meta.authorizationEndpoint, 'https://as.example.com/rfc8414/auth');
    });

    test('falls back to OIDC openid-configuration (PR#797)', () async {
      var triedRfc8414 = false;
      final mock = MockClient((req) async {
        if (req.url.path == '/.well-known/oauth-authorization-server') {
          triedRfc8414 = true;
          return http.Response('nope', 404);
        }
        if (req.url.path == '/.well-known/openid-configuration') {
          return http.Response(
            jsonEncode({
              'issuer': 'https://as.example.com',
              'authorization_endpoint': 'https://as.example.com/oidc/auth',
              'token_endpoint': 'https://as.example.com/oidc/token',
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
      final oauth = HttpOAuthClient(config: cfg(), httpClient: mock);
      final meta =
          await oauth.discoverAuthorizationServer('https://as.example.com');
      expect(triedRfc8414, isTrue, reason: 'RFC 8414 attempted first');
      expect(meta.authorizationEndpoint, 'https://as.example.com/oidc/auth');
      expect(meta.tokenEndpoint, 'https://as.example.com/oidc/token');
    });
  });

  // --------------------------------------------------------------------------
  // A5+A6+A7 — end-to-end discoverFrom401
  // --------------------------------------------------------------------------
  group('discoverFrom401 end-to-end (PRM -> AS -> step-up scope)', () {
    test('resolves endpoints and step-up scope from the challenge', () async {
      final mock = MockClient((req) async {
        switch (req.url.path) {
          case '/.well-known/oauth-protected-resource':
            return http.Response(
              jsonEncode({
                'resource': 'https://api.example.com',
                'authorization_servers': ['https://as.example.com'],
                'scopes_supported': ['mcp:tools', 'mcp:resources'],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          case '/.well-known/oauth-authorization-server':
            return http.Response(
              jsonEncode({
                'issuer': 'https://as.example.com',
                'authorization_endpoint': 'https://as.example.com/auth',
                'token_endpoint': 'https://as.example.com/token',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
        }
        return http.Response('not found', 404);
      });
      final oauth = HttpOAuthClient(
        config: const OAuthConfig(
          authorizationEndpoint: 'https://placeholder/authorize',
          tokenEndpoint: 'https://placeholder/token',
          clientId: 'client-1',
        ),
        httpClient: mock,
      );

      const challengeHeader =
          'Bearer resource_metadata="https://api.example.com/.well-known/'
          'oauth-protected-resource", scope="mcp:tools"';
      final result = await oauth.discoverFrom401(
        resourceUrl: 'https://api.example.com/mcp',
        wwwAuthenticate: challengeHeader,
      );

      expect(result.protectedResource.authorizationServers,
          ['https://as.example.com']);
      expect(result.authServerMetadata.authorizationEndpoint,
          'https://as.example.com/auth');
      // A6: challenge scope wins over PRM scopes_supported for step-up.
      expect(result.stepUpScopes, ['mcp:tools']);

      // The discovered endpoints are now cached — the reused PKCE/token flow
      // builds the authorization URL against the discovered AS.
      final authUrl = await oauth.getAuthorizationUrl(scopes: result.stepUpScopes);
      final parsed = Uri.parse(authUrl);
      expect(parsed.origin + parsed.path, 'https://as.example.com/auth');
      expect(parsed.queryParameters['scope'], 'mcp:tools');
      expect(parsed.queryParameters['code_challenge_method'], 'S256');
    });

    test('falls back to well-known PRM when the header omits it', () async {
      var prmHit = false;
      final mock = MockClient((req) async {
        switch (req.url.path) {
          case '/.well-known/oauth-protected-resource':
            prmHit = true;
            return http.Response(
              jsonEncode({
                'resource': 'https://api.example.com',
                'authorization_servers': ['https://as.example.com'],
                'scopes_supported': ['mcp:all'],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          case '/.well-known/oauth-authorization-server':
            return http.Response(
              jsonEncode({
                'issuer': 'https://as.example.com',
                'authorization_endpoint': 'https://as.example.com/auth',
                'token_endpoint': 'https://as.example.com/token',
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
        }
        return http.Response('not found', 404);
      });
      final oauth = HttpOAuthClient(
        config: const OAuthConfig(
          authorizationEndpoint: 'https://placeholder/authorize',
          tokenEndpoint: 'https://placeholder/token',
          clientId: 'client-1',
        ),
        httpClient: mock,
      );

      // No WWW-Authenticate header at all -> derive PRM URL from resource.
      final result = await oauth.discoverFrom401(
        resourceUrl: 'https://api.example.com/mcp',
      );
      expect(prmHit, isTrue);
      // No challenge scope -> fall back to PRM scopes_supported.
      expect(result.stepUpScopes, ['mcp:all']);
    });
  });

  // --------------------------------------------------------------------------
  // A8 — CIMD (client_id as an https URL, SEP-991)
  // --------------------------------------------------------------------------
  group('A8 Client ID Metadata Document (CIMD)', () {
    test('effectiveClientId prefers the CIMD URL', () {
      final oauth = HttpOAuthClient(
        config: const OAuthConfig(
          authorizationEndpoint: 'https://as.example.com/auth',
          tokenEndpoint: 'https://as.example.com/token',
          clientId: 'registered-id',
          clientIdMetadataUrl: 'https://client.example.com/id.json',
        ),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      expect(oauth.effectiveClientId, 'https://client.example.com/id.json');
    });

    test('registered clientId used when no CIMD URL', () {
      final oauth = HttpOAuthClient(
        config: const OAuthConfig(
          authorizationEndpoint: 'https://as.example.com/auth',
          tokenEndpoint: 'https://as.example.com/token',
          clientId: 'registered-id',
        ),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      expect(oauth.effectiveClientId, 'registered-id');
    });

    test('authorization URL carries the CIMD URL as client_id', () async {
      final oauth = HttpOAuthClient(
        config: const OAuthConfig(
          authorizationEndpoint: 'https://as.example.com/auth',
          tokenEndpoint: 'https://as.example.com/token',
          clientId: 'registered-id',
          clientIdMetadataUrl: 'https://client.example.com/id.json',
        ),
        httpClient: MockClient((_) async => http.Response('', 404)),
      );
      final authUrl = await oauth.getAuthorizationUrl(scopes: ['mcp:tools']);
      final parsed = Uri.parse(authUrl);
      expect(parsed.queryParameters['client_id'],
          'https://client.example.com/id.json');
    });

    test('OAuthConfig round-trips clientIdMetadataUrl', () {
      const c = OAuthConfig(
        authorizationEndpoint: 'https://as.example.com/auth',
        tokenEndpoint: 'https://as.example.com/token',
        clientId: 'registered-id',
        clientIdMetadataUrl: 'https://client.example.com/id.json',
      );
      final restored = OAuthConfig.fromJson(c.toJson());
      expect(restored.clientIdMetadataUrl, 'https://client.example.com/id.json');
    });
  });

  // --------------------------------------------------------------------------
  // A5 — transport 401 enrichment (the client TAKES ACTION on the header)
  // --------------------------------------------------------------------------
  group('A5 transport surfaces parsed challenge on 401', () {
    test('401 response emits resource_metadata + scope in error.data', () async {
      const challenge =
          'Bearer resource_metadata="https://api.example.com/.well-known/'
          'oauth-protected-resource", error="invalid_token", '
          'scope="mcp:tools mcp:resources"';
      final mock = MockClient((req) async => http.Response(
            jsonEncode({'error': 'unauthorized'}),
            401,
            headers: {
              'content-type': 'application/json',
              'www-authenticate': challenge,
            },
          ));
      final transport = await StreamableHttpClientTransport.create(
        baseUrl: 'https://api.example.com/mcp',
        httpClient: mock,
      );

      final firstMessage = transport.onMessage.first;
      transport.send({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});
      final msg = (await firstMessage) as Map;

      final data = (msg['error'] as Map)['data'] as Map;
      expect(data['resource_metadata'],
          'https://api.example.com/.well-known/oauth-protected-resource');
      expect(data['scope'], 'mcp:tools mcp:resources');
      expect(data['resource_url'], 'https://api.example.com/mcp');
      transport.close();
    });
  });
}
