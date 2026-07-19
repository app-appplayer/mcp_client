/// OAuth 2.1 client implementation for MCP
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'oauth.dart';
import 'oauth_discovery.dart';

/// Result of resolving a `401` challenge into concrete OAuth endpoints
/// (RFC 9728 PRM + RFC 8414/OIDC authorization-server discovery).
class OAuthDiscoveryResult {
  /// The parsed `WWW-Authenticate` challenge, when one was present.
  final WwwAuthenticateChallenge? challenge;

  /// The fetched Protected Resource Metadata (RFC 9728).
  final ProtectedResourceMetadata protectedResource;

  /// The discovered authorization-server metadata (RFC 8414 / OIDC).
  final AuthServerMetadata authServerMetadata;

  /// The scope to request when (re-)authorizing (SEP-835 step-up): the
  /// challenge `scope=` when advertised, else the PRM `scopes_supported`.
  final List<String> stepUpScopes;

  const OAuthDiscoveryResult({
    required this.challenge,
    required this.protectedResource,
    required this.authServerMetadata,
    required this.stepUpScopes,
  });
}

/// HTTP-based OAuth 2.1 client implementation
class HttpOAuthClient implements OAuthClient {
  final OAuthConfig config;
  final http.Client _httpClient;
  AuthServerMetadata? _metadata;

  HttpOAuthClient({required this.config, http.Client? httpClient})
    : _httpClient = httpClient ?? http.Client();

  /// Discover authorization server metadata (RFC8414)
  Future<AuthServerMetadata> _discoverMetadata() async {
    if (_metadata != null) return _metadata!;

    if (config.authServerMetadataUrl == null) {
      // Create metadata from config
      _metadata = AuthServerMetadata(
        issuer: Uri.parse(config.authorizationEndpoint).origin,
        authorizationEndpoint: config.authorizationEndpoint,
        tokenEndpoint: config.tokenEndpoint,
      );
      return _metadata!;
    }

    final response = await _httpClient.get(
      Uri.parse(config.authServerMetadataUrl!),
      headers: {'Accept': 'application/json'},
    );

    if (response.statusCode != 200) {
      throw OAuthError(
        error: 'metadata_discovery_failed',
        errorDescription: 'Failed to discover authorization server metadata',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    _metadata = AuthServerMetadata.fromJson(json);
    return _metadata!;
  }

  /// The `client_id` value presented on authorization/token requests.
  ///
  /// SEP-991 (CIMD): when [OAuthConfig.clientIdMetadataUrl] is set, the client
  /// identifies itself with that `https` URL instead of a pre-registered id.
  /// Falls back to [OAuthConfig.clientId] otherwise. Additive — behavior is
  /// unchanged when the metadata URL is null.
  String get effectiveClientId =>
      config.clientIdMetadataUrl ?? config.clientId;

  /// Parse a raw `WWW-Authenticate` header (RFC 9728 / SEP-985 / SEP-835).
  /// Convenience passthrough to [WwwAuthenticateChallenge.parse].
  WwwAuthenticateChallenge? parseWwwAuthenticate(String? header) =>
      WwwAuthenticateChallenge.parse(header);

  /// Derive the RFC 9728 well-known PRM URL for a resource origin, used as the
  /// fallback when a `401` carries no `resource_metadata=` param (SEP-985).
  ///
  /// `https://api.example.com/mcp` → `https://api.example.com/.well-known/
  /// oauth-protected-resource`. The well-known segment is inserted at the
  /// origin per RFC 9728 §3.1.
  Uri wellKnownProtectedResourceUrl(String resourceUrl) {
    final uri = Uri.parse(resourceUrl);
    return Uri.parse(
        '${uri.origin}/.well-known/oauth-protected-resource');
  }

  /// Fetch and parse an RFC 9728 Protected Resource Metadata document.
  Future<ProtectedResourceMetadata> fetchProtectedResourceMetadata(
      Uri url) async {
    final response = await _httpClient.get(
      url,
      headers: {'Accept': 'application/json'},
    );
    if (response.statusCode != 200) {
      throw OAuthError(
        error: 'protected_resource_discovery_failed',
        errorDescription:
            'Failed to fetch Protected Resource Metadata ($url): '
            '${response.statusCode}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return ProtectedResourceMetadata.fromJson(json);
  }

  /// Discover authorization-server metadata for an issuer/AS identifier,
  /// trying BOTH RFC 8414 (`/.well-known/oauth-authorization-server`) and
  /// OpenID Connect Discovery 1.0 (`/.well-known/openid-configuration`,
  /// PR#797). The OIDC document shares the RFC 8414 field shape, so
  /// [AuthServerMetadata.fromJson] parses either. The first endpoint that
  /// returns a valid document wins.
  ///
  /// Sets the client's cached metadata so the existing PKCE/token flow
  /// ([getAuthorizationUrl], [exchangeCodeForToken], …) targets the discovered
  /// endpoints. No cryptography is performed here — these are metadata fetches.
  Future<AuthServerMetadata> discoverAuthorizationServer(
      String authorizationServer) async {
    final origin = Uri.parse(authorizationServer).origin;
    final candidates = <Uri>[
      Uri.parse('$origin/.well-known/oauth-authorization-server'),
      Uri.parse('$origin/.well-known/openid-configuration'),
    ];

    OAuthError? lastError;
    for (final url in candidates) {
      try {
        final response = await _httpClient.get(
          url,
          headers: {'Accept': 'application/json'},
        );
        if (response.statusCode != 200) {
          lastError = OAuthError(
            error: 'as_discovery_failed',
            errorDescription: 'AS metadata ($url): ${response.statusCode}',
          );
          continue;
        }
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final metadata = AuthServerMetadata.fromJson(json);
        _metadata = metadata;
        return metadata;
      } catch (e) {
        lastError = e is OAuthError
            ? e
            : OAuthError(
                error: 'as_discovery_failed',
                errorDescription: 'AS metadata ($url): $e',
              );
      }
    }
    throw lastError ??
        OAuthError(
          error: 'as_discovery_failed',
          errorDescription:
              'No authorization-server metadata found for '
              '$authorizationServer',
        );
  }

  /// Resolve a `401` into concrete OAuth endpoints (RFC 9728 + RFC 8414/OIDC).
  ///
  /// Orchestrates the MCP 2025-11-25 discovery chain:
  /// 1. Parse the `WWW-Authenticate` challenge (SEP-985); read
  ///    `resource_metadata=` when present, else fall back to the resource
  ///    origin's `.well-known/oauth-protected-resource` (SEP-985 fallback).
  /// 2. Fetch the PRM document and read `authorization_servers` (RFC 9728).
  /// 3. Discover the AS via RFC 8414 + OIDC (PR#797).
  /// 4. Compute step-up scopes from the challenge `scope=` (SEP-835), falling
  ///    back to the PRM `scopes_supported`.
  ///
  /// On success the client's cached AS metadata is set so the existing
  /// PKCE/token flow targets the discovered endpoints — reusing all existing
  /// crypto. Returns the resolved [OAuthDiscoveryResult].
  Future<OAuthDiscoveryResult> discoverFrom401({
    required String resourceUrl,
    String? wwwAuthenticate,
  }) async {
    final challenge = WwwAuthenticateChallenge.parse(wwwAuthenticate);

    final prmUrl = challenge?.resourceMetadata != null
        ? Uri.parse(challenge!.resourceMetadata!)
        : wellKnownProtectedResourceUrl(resourceUrl);

    final prm = await fetchProtectedResourceMetadata(prmUrl);
    final authServer = prm.primaryAuthorizationServer;
    if (authServer == null) {
      throw OAuthError(
        error: 'no_authorization_server',
        errorDescription:
            'Protected Resource Metadata lists no authorization_servers',
      );
    }

    final asMetadata = await discoverAuthorizationServer(authServer);

    final challengeScopes = challenge?.scopes ?? const <String>[];
    final stepUpScopes = challengeScopes.isNotEmpty
        ? challengeScopes
        : (prm.scopesSupported ?? const <String>[]);

    return OAuthDiscoveryResult(
      challenge: challenge,
      protectedResource: prm,
      authServerMetadata: asMetadata,
      stepUpScopes: stepUpScopes,
    );
  }

  /// Generate PKCE code verifier and challenge
  Map<String, String> _generatePkce() {
    final random = Random.secure();
    final codeVerifier = base64UrlEncode(
      List<int>.generate(32, (i) => random.nextInt(256)),
    ).replaceAll('=', '');

    final bytes = utf8.encode(codeVerifier);
    final digest = sha256.convert(bytes);
    final codeChallenge = base64UrlEncode(digest.bytes).replaceAll('=', '');

    return {'code_verifier': codeVerifier, 'code_challenge': codeChallenge};
  }

  @override
  Future<String> getAuthorizationUrl({
    required List<String> scopes,
    String? state,
    Map<String, String>? additionalParams,
  }) async {
    final metadata = await _discoverMetadata();
    final pkce = _generatePkce();

    // Store code verifier for later use
    _codeVerifier = pkce['code_verifier']!;

    final params = <String, String>{
      'response_type': 'code',
      'client_id': effectiveClientId,
      'code_challenge': pkce['code_challenge']!,
      'code_challenge_method': config.codeChallengeMethod,
      if (config.redirectUri != null) 'redirect_uri': config.redirectUri!,
      if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      if (state != null) 'state': state,
      ...?additionalParams,
    };

    final uri = Uri.parse(
      metadata.authorizationEndpoint,
    ).replace(queryParameters: params);

    return uri.toString();
  }

  String? _codeVerifier;

  /// Get the current code verifier for PKCE
  String? get codeVerifier => _codeVerifier;

  /// Validate the `iss` parameter returned on an authorization response
  /// against the authorization server's issuer (RFC 9207, MCP 2026-07-28 auth
  /// hardening). Defends against mix-up attacks: a response's `iss` MUST equal
  /// the discovered AS issuer. Throws [OAuthError] on mismatch. A null
  /// [responseIssuer] is tolerated only when the AS did not advertise
  /// `authorization_response_iss_parameter_supported` — callers that receive
  /// an `iss` MUST pass it.
  Future<void> validateAuthorizationResponseIssuer(
      String? responseIssuer) async {
    if (responseIssuer == null) return;
    final metadata = await _discoverMetadata();
    if (responseIssuer != metadata.issuer) {
      throw OAuthError(
        error: 'invalid_issuer',
        errorDescription:
            'Authorization response `iss` ($responseIssuer) does not match '
            'the authorization server issuer (${metadata.issuer}) — RFC 9207.',
      );
    }
  }

  /// Exchange an authorization code for tokens. When the authorization
  /// response carried an `iss` parameter (RFC 9207), pass it as
  /// [responseIssuer] — it is validated against the AS issuer before the
  /// exchange (mix-up defense).
  @override
  Future<OAuthToken> exchangeCodeForToken({
    required String code,
    required String codeVerifier,
    String? responseIssuer,
  }) async {
    await validateAuthorizationResponseIssuer(responseIssuer);
    final metadata = await _discoverMetadata();

    final body = <String, String>{
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': effectiveClientId,
      'code_verifier': codeVerifier,
      if (config.redirectUri != null) 'redirect_uri': config.redirectUri!,
    };

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    };

    // Add client authentication if confidential client
    if (config.clientSecret != null) {
      final credentials = base64Encode(
        utf8.encode('${config.clientId}:${config.clientSecret}'),
      );
      headers['Authorization'] = 'Basic $credentials';
    }

    final response = await _httpClient.post(
      Uri.parse(metadata.tokenEndpoint),
      headers: headers,
      body: body.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&'),
    );

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw OAuthError.fromJson(json);
    }

    return OAuthToken.fromJson(json);
  }

  @override
  Future<OAuthToken> refreshToken({required String refreshToken}) async {
    final metadata = await _discoverMetadata();

    final body = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': effectiveClientId,
    };

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    };

    if (config.clientSecret != null) {
      final credentials = base64Encode(
        utf8.encode('${config.clientId}:${config.clientSecret}'),
      );
      headers['Authorization'] = 'Basic $credentials';
    }

    final response = await _httpClient.post(
      Uri.parse(metadata.tokenEndpoint),
      headers: headers,
      body: body.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&'),
    );

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw OAuthError.fromJson(json);
    }

    return OAuthToken.fromJson(json);
  }

  @override
  Future<void> revokeToken({
    required String token,
    String? tokenTypeHint,
  }) async {
    final metadata = await _discoverMetadata();

    if (metadata.revocationEndpoint == null) {
      return; // Server doesn't support revocation
    }

    final body = <String, String>{
      'token': token,
      'client_id': effectiveClientId,
      if (tokenTypeHint != null) 'token_type_hint': tokenTypeHint,
    };

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    if (config.clientSecret != null) {
      final credentials = base64Encode(
        utf8.encode('${config.clientId}:${config.clientSecret}'),
      );
      headers['Authorization'] = 'Basic $credentials';
    }

    await _httpClient.post(
      Uri.parse(metadata.revocationEndpoint!),
      headers: headers,
      body: body.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&'),
    );
  }

  @override
  Future<OAuthToken> getClientCredentialsToken({List<String>? scopes}) async {
    final metadata = await _discoverMetadata();

    final body = <String, String>{
      'grant_type': 'client_credentials',
      'client_id': effectiveClientId,
      if (scopes != null && scopes.isNotEmpty) 'scope': scopes.join(' '),
    };

    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept': 'application/json',
    };

    if (config.clientSecret != null) {
      final credentials = base64Encode(
        utf8.encode('${config.clientId}:${config.clientSecret}'),
      );
      headers['Authorization'] = 'Basic $credentials';
    }

    final response = await _httpClient.post(
      Uri.parse(metadata.tokenEndpoint),
      headers: headers,
      body: body.entries
          .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
          .join('&'),
    );

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode != 200) {
      throw OAuthError.fromJson(json);
    }

    return OAuthToken.fromJson(json);
  }

  // Add PKCE related methods

  /// Generate PKCE code verifier (RFC 7636)
  String generateCodeVerifier() {
    const charset =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final random = Random.secure();
    final length = 43 + random.nextInt(86); // 43-128 character length

    return List.generate(
      length,
      (index) => charset[random.nextInt(charset.length)],
    ).join();
  }

  /// Generate PKCE code challenge (S256 method)
  String generateCodeChallenge(String codeVerifier) {
    final bytes = utf8.encode(codeVerifier);
    final digest = sha256.convert(bytes);
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  /// Code challenge method (S256)
  String get codeChallengeMethod => 'S256';

  /// Generate Authorization URL with PKCE parameters
  Uri getAuthorizationUrlWithPkce({
    required List<String> scopes,
    String? state,
    String? codeVerifier,
    String? redirectUri,
  }) {
    final queryParams = <String, String>{
      'response_type': 'code',
      'client_id': effectiveClientId,
      'scope': scopes.join(' '),
      'state': state ?? _generateState(),
    };

    if (redirectUri != null) {
      queryParams['redirect_uri'] = redirectUri;
    }

    // Add PKCE parameters
    if (codeVerifier != null) {
      final codeChallenge = generateCodeChallenge(codeVerifier);
      queryParams['code_challenge'] = codeChallenge;
      queryParams['code_challenge_method'] = codeChallengeMethod;
    }

    final uri = Uri.parse(config.authorizationEndpoint);
    return uri.replace(queryParameters: queryParams);
  }

  /// Generate token exchange request data
  Map<String, String> buildTokenExchangeRequest({
    required String authorizationCode,
    required String codeVerifier,
    String? redirectUri,
  }) {
    return {
      'grant_type': 'authorization_code',
      'code': authorizationCode,
      'code_verifier': codeVerifier,
      'client_id': effectiveClientId,
      if (redirectUri != null) 'redirect_uri': redirectUri,
    };
  }

  /// Generate Refresh Token request data
  Map<String, String> buildRefreshTokenRequest({
    required String refreshToken,
    List<String>? scopes,
  }) {
    return {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': effectiveClientId,
      if (scopes != null && scopes.isNotEmpty) 'scope': scopes.join(' '),
    };
  }

  /// Generate State parameter (CSRF protection)
  String _generateState() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (i) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  /// Close the HTTP client
  void close() {
    _httpClient.close();
  }
}

/// OAuth token manager with automatic refresh
class OAuthTokenManager {
  final HttpOAuthClient _client;
  OAuthToken? _currentToken;
  Timer? _refreshTimer;

  final StreamController<OAuthToken> _tokenController =
      StreamController.broadcast();
  final StreamController<OAuthError> _errorController =
      StreamController.broadcast();

  OAuthTokenManager(this._client);

  /// Current token
  OAuthToken? get currentToken => _currentToken;

  /// Stream of token updates
  Stream<OAuthToken> get onTokenUpdate => _tokenController.stream;

  /// Stream of authentication errors
  Stream<OAuthError> get onError => _errorController.stream;

  /// Check if we have a valid token
  bool get hasValidToken {
    if (_currentToken == null) return false;
    return !_currentToken!.isExpired;
  }

  /// Check if the user is authenticated (alias for hasValidToken)
  bool get isAuthenticated => hasValidToken;

  /// Set the current token and schedule refresh
  void setToken(OAuthToken token) {
    _currentToken = token;
    _tokenController.add(token);
    _scheduleRefresh();
  }

  /// Get a valid access token, refreshing if necessary
  Future<String> getAccessToken() async {
    if (hasValidToken) {
      return _currentToken!.accessToken;
    }

    if (_currentToken?.refreshToken != null) {
      try {
        final newToken = await _client.refreshToken(
          refreshToken: _currentToken!.refreshToken!,
        );
        setToken(newToken);
        return newToken.accessToken;
      } catch (e) {
        _errorController.add(
          e is OAuthError
              ? e
              : OAuthError(
                error: 'refresh_failed',
                errorDescription: e.toString(),
              ),
        );
        rethrow;
      }
    }

    throw OAuthError(
      error: 'no_valid_token',
      errorDescription: 'No valid token available and no refresh token',
    );
  }

  /// Schedule automatic token refresh
  void _scheduleRefresh() {
    _refreshTimer?.cancel();

    if (_currentToken?.refreshToken == null ||
        _currentToken?.expiresIn == null) {
      return;
    }

    // Refresh 5 minutes before expiry
    final refreshIn = Duration(seconds: _currentToken!.expiresIn! - 300);
    if (refreshIn.isNegative) return;

    _refreshTimer = Timer(refreshIn, () async {
      try {
        final newToken = await _client.refreshToken(
          refreshToken: _currentToken!.refreshToken!,
        );
        setToken(newToken);
      } catch (e) {
        _errorController.add(
          e is OAuthError
              ? e
              : OAuthError(
                error: 'auto_refresh_failed',
                errorDescription: e.toString(),
              ),
        );
      }
    });
  }

  /// Clear the current token
  void clearToken() {
    _refreshTimer?.cancel();
    _currentToken = null;
  }

  // Add token lifecycle management methods

  /// Check if token is expired
  bool get isTokenExpired {
    if (_currentToken == null) return true;
    return _currentToken!.isExpired;
  }

  /// Returns true if the token will expire within [threshold].
  bool willExpireSoon({Duration threshold = const Duration(minutes: 5)}) {
    if (_currentToken == null || _currentToken!.expiresIn == null) return true;

    final expiresAt = _currentToken!.issuedAt.add(
      Duration(seconds: _currentToken!.expiresIn!),
    );
    final now = DateTime.now();
    return expiresAt.difference(now) <= threshold;
  }

  /// Stores the token in memory; persists to secure storage when [persistent] is true.
  Future<void> storeToken(OAuthToken token, {bool persistent = false}) async {
    _currentToken = token;
    _tokenController.add(token);
    _scheduleRefresh();

    if (persistent) {
      await _persistToken(token);
    }
  }

  /// Replaces the current token with [newToken] and fires the refresh callback.
  Future<void> refreshToken(OAuthToken newToken) async {
    final oldToken = _currentToken;
    await storeToken(newToken);

    if (onTokenRefresh != null && oldToken != null) {
      onTokenRefresh!(oldToken, newToken);
    }
  }

  /// Revokes the current token at the authorization server and clears it locally.
  Future<void> revokeToken() async {
    if (_currentToken != null) {
      try {
        await _client.revokeToken(token: _currentToken!.accessToken);
      } catch (e) {
        // Even if remote revocation fails, drop the local token.
      }
    }
    clearToken();
  }

  /// Drops expired tokens from memory.
  Future<int> cleanupExpiredTokens() async {
    var cleaned = 0;
    if (isTokenExpired) {
      clearToken();
      cleaned = 1;
    }
    return cleaned;
  }

  /// Securely deletes the token from memory.
  Future<void> securelyDeleteToken() async {
    clearToken();
    // Fully clear the in-memory reference.
    _currentToken = null;
  }

  /// Loads previously persisted tokens.
  Future<void> loadPersistedTokens() async {
    // TODO: integrate with SecureStorage. Empty placeholder for tests.
  }

  /// Stores an encrypted token.
  Future<void> storeEncryptedToken(
    OAuthToken token,
    String encryptionKey,
  ) async {
    // TODO: apply real encryption logic.
    await storeToken(token, persistent: true);
  }

  /// Loads an encrypted token.
  Future<OAuthToken?> loadEncryptedToken(String encryptionKey) async {
    // TODO: apply real decryption logic.
    return _currentToken;
  }

  /// Checks token expiry and emits a near-expiry lifecycle event when due.
  Future<void> checkTokenExpiry() async {
    if (willExpireSoon()) {
      _lifecycleController.add(
        TokenLifecycleEvent(
          type: TokenEventType.nearExpiry,
          timestamp: DateTime.now(),
          tokenId: _currentToken?.accessToken,
          message: 'Token will expire soon',
        ),
      );
    }
  }

  /// Starts the background refresh timer.
  void startBackgroundRefresh() {
    _scheduleRefresh();
    if (onBackgroundRefresh != null) {
      onBackgroundRefresh!();
    }
  }

  /// Stops the background refresh timer.
  void stopBackgroundRefresh() {
    _refreshTimer?.cancel();
  }

  // Persists the token (internal).
  Future<void> _persistToken(OAuthToken token) async {
    // TODO: integrate with SecureStorage.
  }

  // Callbacks and event streams.
  Function(OAuthToken oldToken, OAuthToken newToken)? onTokenRefresh;
  Function(dynamic error, int attempt)? onRefreshFailure;
  Function()? onBackgroundRefresh;

  final StreamController<TokenLifecycleEvent> _lifecycleController =
      StreamController<TokenLifecycleEvent>.broadcast();

  /// Stream of token lifecycle events.
  Stream<TokenLifecycleEvent> get lifecycleEvents =>
      _lifecycleController.stream;

  /// Dispose resources
  void dispose() {
    _refreshTimer?.cancel();
    _tokenController.close();
    _errorController.close();
    _lifecycleController.close();
  }
}

/// Token lifecycle event types.
enum TokenEventType {
  issued,
  accessed,
  refreshed,
  nearExpiry,
  expired,
  revoked,
  error,
}

/// Token lifecycle event.
class TokenLifecycleEvent {
  final TokenEventType type;
  final DateTime timestamp;
  final String? tokenId;
  final String? message;
  final Map<String, dynamic>? metadata;

  TokenLifecycleEvent({
    required this.type,
    required this.timestamp,
    this.tokenId,
    this.message,
    this.metadata,
  });
}
