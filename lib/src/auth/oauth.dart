/// OAuth 2.1 authentication support for MCP
library;

import 'package:meta/meta.dart';

/// OAuth 2.1 grant types supported by MCP
enum OAuthGrantType {
  /// Authorization code flow for human users
  authorizationCode,

  /// Client credentials flow for machine-to-machine
  clientCredentials,

  /// Refresh token flow
  refreshToken,
}

/// OAuth 2.1 authentication configuration
@immutable
class OAuthConfig {
  /// Authorization server metadata URL (RFC8414)
  final String? authServerMetadataUrl;

  /// Authorization endpoint URL
  final String authorizationEndpoint;

  /// Token endpoint URL
  final String tokenEndpoint;

  /// Client ID
  final String clientId;

  /// Client secret (for confidential clients)
  final String? clientSecret;

  /// Redirect URI
  final String? redirectUri;

  /// Scopes to request
  final List<String> scopes;

  /// Grant type to use
  final OAuthGrantType grantType;

  /// PKCE code challenge method
  final String codeChallengeMethod;

  const OAuthConfig({
    this.authServerMetadataUrl,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    this.redirectUri,
    this.scopes = const [],
    this.grantType = OAuthGrantType.authorizationCode,
    this.codeChallengeMethod = 'S256',
  });

  Map<String, dynamic> toJson() => {
    if (authServerMetadataUrl != null)
      'authServerMetadataUrl': authServerMetadataUrl,
    'authorizationEndpoint': authorizationEndpoint,
    'tokenEndpoint': tokenEndpoint,
    'clientId': clientId,
    if (clientSecret != null) 'clientSecret': clientSecret,
    if (redirectUri != null) 'redirectUri': redirectUri,
    'scopes': scopes,
    'grantType': grantType.name,
    'codeChallengeMethod': codeChallengeMethod,
  };

  factory OAuthConfig.fromJson(Map<String, dynamic> json) => OAuthConfig(
    authServerMetadataUrl: json['authServerMetadataUrl'] as String?,
    authorizationEndpoint: json['authorizationEndpoint'] as String,
    tokenEndpoint: json['tokenEndpoint'] as String,
    clientId: json['clientId'] as String,
    clientSecret: json['clientSecret'] as String?,
    redirectUri: json['redirectUri'] as String?,
    scopes: (json['scopes'] as List<dynamic>?)?.cast<String>() ?? const [],
    grantType: OAuthGrantType.values.firstWhere(
      (e) => e.name == json['grantType'],
      orElse: () => OAuthGrantType.authorizationCode,
    ),
    codeChallengeMethod: json['codeChallengeMethod'] as String? ?? 'S256',
  );
}

/// OAuth 2.1 token response
@immutable
class OAuthToken {
  /// Access token
  final String accessToken;

  /// Token type (usually "Bearer")
  final String tokenType;

  /// Expiration time in seconds
  final int? expiresIn;

  /// Refresh token
  final String? refreshToken;

  /// Scopes granted
  final List<String>? scopes;

  /// Token issue time
  final DateTime issuedAt;

  /// Additional token data
  final Map<String, dynamic>? extra;

  const OAuthToken({
    required this.accessToken,
    this.tokenType = 'Bearer',
    this.expiresIn,
    this.refreshToken,
    this.scopes,
    required this.issuedAt,
    this.extra,
  });

  /// Get scope as a single string
  String? get scope => scopes?.join(' ');

  /// Get token expiry time
  DateTime? get expiresAt {
    if (expiresIn == null) return null;
    return issuedAt.add(Duration(seconds: expiresIn!));
  }

  /// Check if token is expired
  bool get isExpired {
    if (expiresIn == null) return false;
    final expiryTime = issuedAt.add(Duration(seconds: expiresIn!));
    return DateTime.now().isAfter(expiryTime);
  }

  /// Get remaining lifetime in seconds
  int? get remainingLifetime {
    if (expiresIn == null) return null;
    final expiryTime = issuedAt.add(Duration(seconds: expiresIn!));
    final remaining = expiryTime.difference(DateTime.now()).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  Map<String, dynamic> toJson() => {
    'access_token': accessToken,
    'token_type': tokenType,
    if (expiresIn != null) 'expires_in': expiresIn,
    if (refreshToken != null) 'refresh_token': refreshToken,
    if (scopes != null) 'scope': scopes!.join(' '),
    'issued_at': issuedAt.millisecondsSinceEpoch,
  };

  factory OAuthToken.fromJson(Map<String, dynamic> json) {
    final extra = Map<String, dynamic>.from(json);
    // Remove standard fields
    extra.removeWhere(
      (key, value) => [
        'access_token',
        'token_type',
        'expires_in',
        'refresh_token',
        'scope',
        'issued_at',
      ].contains(key),
    );

    return OAuthToken(
      accessToken: json['access_token'] as String,
      tokenType: json['token_type'] as String? ?? 'Bearer',
      expiresIn: json['expires_in'] as int?,
      refreshToken: json['refresh_token'] as String?,
      scopes:
          json['scope'] != null ? (json['scope'] as String).split(' ') : null,
      issuedAt:
          json['issued_at'] != null
              ? DateTime.fromMillisecondsSinceEpoch(json['issued_at'] as int)
              : DateTime.now(),
      extra: extra.isNotEmpty ? extra : null,
    );
  }
}

/// Authorization server metadata (RFC8414)
@immutable
class AuthServerMetadata {
  /// Issuer identifier
  final String issuer;

  /// Authorization endpoint
  final String authorizationEndpoint;

  /// Token endpoint
  final String tokenEndpoint;

  /// Token endpoint auth methods supported
  final List<String> tokenEndpointAuthMethodsSupported;

  /// Response types supported
  final List<String> responseTypesSupported;

  /// Grant types supported
  final List<String> grantTypesSupported;

  /// Code challenge methods supported
  final List<String> codeChallengeMethodsSupported;

  /// Registration endpoint
  final String? registrationEndpoint;

  /// Revocation endpoint
  final String? revocationEndpoint;

  /// Introspection endpoint
  final String? introspectionEndpoint;

  const AuthServerMetadata({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.tokenEndpointAuthMethodsSupported = const ['client_secret_basic'],
    this.responseTypesSupported = const ['code'],
    this.grantTypesSupported = const ['authorization_code', 'refresh_token'],
    this.codeChallengeMethodsSupported = const ['S256'],
    this.registrationEndpoint,
    this.revocationEndpoint,
    this.introspectionEndpoint,
  });

  factory AuthServerMetadata.fromJson(Map<String, dynamic> json) =>
      AuthServerMetadata(
        issuer: json['issuer'] as String,
        authorizationEndpoint: json['authorization_endpoint'] as String,
        tokenEndpoint: json['token_endpoint'] as String,
        tokenEndpointAuthMethodsSupported:
            (json['token_endpoint_auth_methods_supported'] as List<dynamic>?)
                ?.cast<String>() ??
            const ['client_secret_basic'],
        responseTypesSupported:
            (json['response_types_supported'] as List<dynamic>?)
                ?.cast<String>() ??
            const ['code'],
        grantTypesSupported:
            (json['grant_types_supported'] as List<dynamic>?)?.cast<String>() ??
            const ['authorization_code', 'refresh_token'],
        codeChallengeMethodsSupported:
            (json['code_challenge_methods_supported'] as List<dynamic>?)
                ?.cast<String>() ??
            const ['S256'],
        registrationEndpoint: json['registration_endpoint'] as String?,
        revocationEndpoint: json['revocation_endpoint'] as String?,
        introspectionEndpoint: json['introspection_endpoint'] as String?,
      );
}

/// OAuth error response
@immutable
class OAuthError {
  /// Error code
  final String error;

  /// Human-readable error description
  final String? errorDescription;

  /// URI for more information
  final String? errorUri;

  const OAuthError({required this.error, this.errorDescription, this.errorUri});

  factory OAuthError.fromJson(Map<String, dynamic> json) => OAuthError(
    error: json['error'] as String,
    errorDescription: json['error_description'] as String?,
    errorUri: json['error_uri'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'error': error,
    if (errorDescription != null) 'error_description': errorDescription,
    if (errorUri != null) 'error_uri': errorUri,
  };

  @override
  String toString() =>
      'OAuthError: $error${errorDescription != null ? ' - $errorDescription' : ''}';
}

/// OAuth client interface
abstract class OAuthClient {
  /// Get authorization URL
  Future<String> getAuthorizationUrl({
    required List<String> scopes,
    String? state,
    Map<String, String>? additionalParams,
  });

  /// Exchange authorization code for token
  Future<OAuthToken> exchangeCodeForToken({
    required String code,
    required String codeVerifier,
  });

  /// Refresh access token
  Future<OAuthToken> refreshToken({required String refreshToken});

  /// Revoke token
  Future<void> revokeToken({required String token, String? tokenTypeHint});

  /// Get token using client credentials
  Future<OAuthToken> getClientCredentialsToken({List<String>? scopes});
}
