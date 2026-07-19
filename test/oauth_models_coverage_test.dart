/// Coverage for the pure-logic pieces of `lib/src/auth/oauth.dart` (config /
/// token / error value objects) and the one remaining branch in
/// `lib/src/auth/oauth_discovery.dart`. Network-performing OAuth client code
/// (`oauth_client.dart` token POST) is explicitly out of scope per the HOLD
/// THE LINE rule — only non-network parse/serialize logic is targeted here.
library;

import 'package:mcp_client/mcp_client.dart';
import 'package:test/test.dart';

void main() {
  group('OAuthGrantType', () {
    test('all three grant types serialize by name via OAuthConfig', () {
      for (final grantType in OAuthGrantType.values) {
        final config = OAuthConfig(
          authorizationEndpoint: 'https://a.example/auth',
          tokenEndpoint: 'https://a.example/token',
          clientId: 'c1',
          grantType: grantType,
        );
        expect(config.toJson()['grantType'], grantType.name);
      }
    });
  });

  group('OAuthConfig', () {
    test('toJson/fromJson round-trip with all optional fields set', () {
      const config = OAuthConfig(
        authServerMetadataUrl: 'https://a.example/.well-known/oauth-as',
        authorizationEndpoint: 'https://a.example/auth',
        tokenEndpoint: 'https://a.example/token',
        clientId: 'c1',
        clientIdMetadataUrl: 'https://client.example/cimd.json',
        clientSecret: 's3cr3t',
        redirectUri: 'https://app.example/callback',
        scopes: ['openid', 'profile'],
        grantType: OAuthGrantType.clientCredentials,
        codeChallengeMethod: 'plain',
      );
      final json = config.toJson();
      expect(json['authServerMetadataUrl'],
          'https://a.example/.well-known/oauth-as');
      expect(json['clientIdMetadataUrl'], 'https://client.example/cimd.json');
      expect(json['clientSecret'], 's3cr3t');
      expect(json['redirectUri'], 'https://app.example/callback');
      expect(json['scopes'], ['openid', 'profile']);
      expect(json['grantType'], 'clientCredentials');
      expect(json['codeChallengeMethod'], 'plain');

      final decoded = OAuthConfig.fromJson(json);
      expect(decoded.authServerMetadataUrl, config.authServerMetadataUrl);
      expect(decoded.clientIdMetadataUrl, config.clientIdMetadataUrl);
      expect(decoded.clientSecret, config.clientSecret);
      expect(decoded.redirectUri, config.redirectUri);
      expect(decoded.scopes, config.scopes);
      expect(decoded.grantType, OAuthGrantType.clientCredentials);
      expect(decoded.codeChallengeMethod, 'plain');
    });

    test('toJson omits absent optionals; fromJson applies defaults', () {
      const config = OAuthConfig(
        authorizationEndpoint: 'https://a.example/auth',
        tokenEndpoint: 'https://a.example/token',
        clientId: 'c1',
      );
      final json = config.toJson();
      expect(json.containsKey('authServerMetadataUrl'), isFalse);
      expect(json.containsKey('clientIdMetadataUrl'), isFalse);
      expect(json.containsKey('clientSecret'), isFalse);
      expect(json.containsKey('redirectUri'), isFalse);
      expect(json['scopes'], isEmpty);
      expect(json['grantType'], 'authorizationCode');
      expect(json['codeChallengeMethod'], 'S256');

      final decoded = OAuthConfig.fromJson({
        'authorizationEndpoint': 'https://a.example/auth',
        'tokenEndpoint': 'https://a.example/token',
        'clientId': 'c1',
      });
      expect(decoded.scopes, isEmpty);
      expect(decoded.grantType, OAuthGrantType.authorizationCode);
      expect(decoded.codeChallengeMethod, 'S256');
    });

    test('fromJson falls back to authorizationCode for an unknown grantType',
        () {
      final decoded = OAuthConfig.fromJson({
        'authorizationEndpoint': 'https://a.example/auth',
        'tokenEndpoint': 'https://a.example/token',
        'clientId': 'c1',
        'grantType': 'not-a-real-grant-type',
      });
      expect(decoded.grantType, OAuthGrantType.authorizationCode);
    });
  });

  group('OAuthToken', () {
    test('isExpired / expiresAt / remainingLifetime are null-safe with no expiresIn',
        () {
      final token = OAuthToken(accessToken: 'tok', issuedAt: DateTime.now());
      expect(token.isExpired, isFalse);
      expect(token.expiresAt, isNull);
      expect(token.remainingLifetime, isNull);
    });

    test('a freshly issued token with expiresIn is not expired', () {
      final token = OAuthToken(
        accessToken: 'tok',
        expiresIn: 3600,
        issuedAt: DateTime.now(),
      );
      expect(token.isExpired, isFalse);
      expect(token.expiresAt, isNotNull);
      expect(token.remainingLifetime, greaterThan(0));
    });

    test('a token issued in the past beyond expiresIn is expired', () {
      final token = OAuthToken(
        accessToken: 'tok',
        expiresIn: 10,
        issuedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      expect(token.isExpired, isTrue);
      expect(token.remainingLifetime, 0);
    });

    test('scope getter joins the scopes list', () {
      final token = OAuthToken(
        accessToken: 'tok',
        scopes: ['a', 'b'],
        issuedAt: DateTime.now(),
      );
      expect(token.scope, 'a b');
    });

    test('toJson emits optional fields only when set', () {
      final full = OAuthToken(
        accessToken: 'tok',
        expiresIn: 3600,
        refreshToken: 'refresh1',
        scopes: ['a', 'b'],
        issuedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final json = full.toJson();
      expect(json['access_token'], 'tok');
      expect(json['token_type'], 'Bearer');
      expect(json['expires_in'], 3600);
      expect(json['refresh_token'], 'refresh1');
      expect(json['scope'], 'a b');
      expect(json['issued_at'], 1000);

      final bare = OAuthToken(accessToken: 'tok', issuedAt: DateTime.now());
      final bareJson = bare.toJson();
      expect(bareJson.containsKey('expires_in'), isFalse);
      expect(bareJson.containsKey('refresh_token'), isFalse);
      expect(bareJson.containsKey('scope'), isFalse);
    });

    test('fromJson round-trips with extra vendor fields preserved', () {
      final json = {
        'access_token': 'tok',
        'token_type': 'Bearer',
        'expires_in': 3600,
        'refresh_token': 'refresh1',
        'scope': 'a b',
        'issued_at': 1000,
        'vendor_field': 'x',
      };
      final decoded = OAuthToken.fromJson(json);
      expect(decoded.accessToken, 'tok');
      expect(decoded.tokenType, 'Bearer');
      expect(decoded.expiresIn, 3600);
      expect(decoded.refreshToken, 'refresh1');
      expect(decoded.scopes, ['a', 'b']);
      expect(decoded.issuedAt, DateTime.fromMillisecondsSinceEpoch(1000));
      expect(decoded.extra, {'vendor_field': 'x'});
    });

    test('fromJson defaults token_type and issued_at, extra is null when bare',
        () {
      final decoded = OAuthToken.fromJson({'access_token': 'tok'});
      expect(decoded.tokenType, 'Bearer');
      expect(decoded.scopes, isNull);
      expect(decoded.extra, isNull);
      // issued_at defaults to "now" when absent.
      expect(
        decoded.issuedAt.difference(DateTime.now()).inSeconds.abs(),
        lessThan(5),
      );
    });
  });

  group('OAuthError', () {
    test('fromJson/toJson round-trip with optional fields set', () {
      final error = OAuthError.fromJson({
        'error': 'invalid_token',
        'error_description': 'token expired',
        'error_uri': 'https://a.example/errors/invalid_token',
      });
      expect(error.error, 'invalid_token');
      expect(error.errorDescription, 'token expired');
      expect(error.errorUri, 'https://a.example/errors/invalid_token');

      final json = error.toJson();
      expect(json['error'], 'invalid_token');
      expect(json['error_description'], 'token expired');
      expect(json['error_uri'], 'https://a.example/errors/invalid_token');
    });

    test('toJson omits absent optional fields', () {
      const error = OAuthError(error: 'invalid_request');
      final json = error.toJson();
      expect(json, {'error': 'invalid_request'});
    });

    test('toString includes description only when present', () {
      const withDescription =
          OAuthError(error: 'invalid_token', errorDescription: 'expired');
      expect(withDescription.toString(), 'OAuthError: invalid_token - expired');

      const bare = OAuthError(error: 'invalid_token');
      expect(bare.toString(), 'OAuthError: invalid_token');
    });
  });

  group('ProtectedResourceMetadata.fromJson (oauth_discovery.dart)', () {
    test('defaults authorization_servers to empty list when absent', () {
      final metadata = ProtectedResourceMetadata.fromJson({
        'resource': 'https://api.example.com',
      });
      expect(metadata.authorizationServers, isEmpty);
      expect(metadata.primaryAuthorizationServer, isNull);
    });

    test('parses scopes_supported and bearer_methods_supported when present',
        () {
      final metadata = ProtectedResourceMetadata.fromJson({
        'resource': 'https://api.example.com',
        'authorization_servers': ['https://as.example.com'],
        'scopes_supported': ['read', 'write'],
        'bearer_methods_supported': ['header'],
        'resource_documentation': 'https://api.example.com/docs',
      });
      expect(metadata.scopesSupported, ['read', 'write']);
      expect(metadata.bearerMethodsSupported, ['header']);
      expect(metadata.resourceDocumentation, 'https://api.example.com/docs');
      expect(metadata.primaryAuthorizationServer, 'https://as.example.com');
    });
  });

  group('AuthServerMetadata.fromJson', () {
    test('parses every RFC 8414 field, overriding the built-in defaults', () {
      final metadata = AuthServerMetadata.fromJson({
        'issuer': 'https://as.example.com',
        'authorization_endpoint': 'https://as.example.com/authorize',
        'token_endpoint': 'https://as.example.com/token',
        'token_endpoint_auth_methods_supported': ['client_secret_post'],
        'response_types_supported': ['code', 'token'],
        'grant_types_supported': ['authorization_code'],
        'code_challenge_methods_supported': ['S256', 'plain'],
        'registration_endpoint': 'https://as.example.com/register',
        'revocation_endpoint': 'https://as.example.com/revoke',
        'introspection_endpoint': 'https://as.example.com/introspect',
      });
      expect(metadata.issuer, 'https://as.example.com');
      expect(metadata.tokenEndpointAuthMethodsSupported,
          ['client_secret_post']);
      expect(metadata.responseTypesSupported, ['code', 'token']);
      expect(metadata.grantTypesSupported, ['authorization_code']);
      expect(metadata.codeChallengeMethodsSupported, ['S256', 'plain']);
      expect(metadata.registrationEndpoint, 'https://as.example.com/register');
      expect(metadata.revocationEndpoint, 'https://as.example.com/revoke');
      expect(
          metadata.introspectionEndpoint, 'https://as.example.com/introspect');
    });

    test('applies RFC 8414 defaults for absent optional list fields', () {
      final metadata = AuthServerMetadata.fromJson({
        'issuer': 'https://as.example.com',
        'authorization_endpoint': 'https://as.example.com/authorize',
        'token_endpoint': 'https://as.example.com/token',
      });
      expect(
          metadata.tokenEndpointAuthMethodsSupported, ['client_secret_basic']);
      expect(metadata.responseTypesSupported, ['code']);
      expect(metadata.grantTypesSupported,
          ['authorization_code', 'refresh_token']);
      expect(metadata.codeChallengeMethodsSupported, ['S256']);
      expect(metadata.registrationEndpoint, isNull);
      expect(metadata.revocationEndpoint, isNull);
      expect(metadata.introspectionEndpoint, isNull);
    });
  });
}
