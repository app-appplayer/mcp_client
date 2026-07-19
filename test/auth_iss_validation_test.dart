/// R4 auth hardening (MCP 2026-07-28) — RFC 9207 `iss` validation on the
/// authorization response (mix-up defense). Additive; a null `iss` is
/// tolerated so pre-9207 flows are unaffected.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('R4 — RFC 9207 iss validation', () {
    // Config with no explicit metadata URL → issuer is synthesized as the
    // authorization endpoint origin (https://as.example.com).
    final client = HttpOAuthClient(
      config: const OAuthConfig(
        authorizationEndpoint: 'https://as.example.com/authorize',
        tokenEndpoint: 'https://as.example.com/token',
        clientId: 'c',
      ),
    );

    test('matching iss passes', () async {
      await client.validateAuthorizationResponseIssuer('https://as.example.com');
    });

    test('mismatched iss throws invalid_issuer (RFC 9207)', () async {
      expect(
        () => client.validateAuthorizationResponseIssuer('https://evil.example'),
        throwsA(isA<OAuthError>()
            .having((e) => e.error, 'error', 'invalid_issuer')),
      );
    });

    test('null iss is tolerated (pre-9207 / not advertised)', () async {
      await client.validateAuthorizationResponseIssuer(null);
    });
  });
}
