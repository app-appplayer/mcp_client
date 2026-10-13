/// OAuth 2.1 client implementation for MCP
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'mcp_oauth.dart';
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
      // Endpoints the host configured itself; it vouches for PKCE.
      _metadata = AuthServerMetadata(
        issuer: Uri.parse(config.authorizationEndpoint).origin,
        authorizationEndpoint: config.authorizationEndpoint,
        tokenEndpoint: config.tokenEndpoint,
        codeChallengeMethodsSupported: [config.codeChallengeMethod],
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

  /// The RFC 9728 well-known PRM URL tried first when a `401` carries no
  /// `resource_metadata=`: at the resource's path
  /// (`https://api.example.com/.well-known/oauth-protected-resource/mcp`);
  /// the root follows (see [protectedResourceMetadataUrls]).
  Uri wellKnownProtectedResourceUrl(String resourceUrl) =>
      protectedResourceMetadataUrls(resourceUrl).first;

  /// The MCP server the tokens are for (RFC 8707 `resource`): the
  /// configured one, else the one discovery found.
  String? get resource => config.resource ?? _resource;
  String? _resource;

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

  /// Discover authorization-server metadata for the issuer
  /// [authorizationServer]: RFC 8414 and OpenID Connect Discovery at each
  /// well-known location in turn (path insertion first). The document must
  /// name [authorizationServer] as its issuer exactly, or it is refused.
  ///
  /// Sets the client's cached metadata so the PKCE/token flow targets it.
  Future<AuthServerMetadata> discoverAuthorizationServer(
      String authorizationServer) async {
    OAuthError? lastError;
    for (final url in authorizationServerMetadataUrls(authorizationServer)) {
      final http.Response response;
      try {
        response = await _httpClient.get(url, headers: {'Accept': 'application/json'});
      } catch (e) {
        lastError = OAuthError(error: 'as_discovery_failed', errorDescription: 'AS metadata ($url): $e');
        continue;
      }
      if (response.statusCode != 200) {
        lastError = OAuthError(
            error: 'as_discovery_failed', errorDescription: 'AS metadata ($url): ${response.statusCode}');
        continue;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['issuer'] != authorizationServer) {
        throw OAuthError(
          error: 'invalid_issuer',
          errorDescription: 'Metadata at $url names issuer ${json['issuer']}, not $authorizationServer',
        );
      }
      final metadata = AuthServerMetadata.fromJson(json);
      _metadata = metadata;
      return metadata;
    }
    throw lastError ??
        OAuthError(
          error: 'as_discovery_failed',
          errorDescription: 'No authorization-server metadata found for $authorizationServer',
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

    final candidates = challenge?.resourceMetadata != null
        ? [Uri.parse(challenge!.resourceMetadata!)]
        : protectedResourceMetadataUrls(resourceUrl);
    ProtectedResourceMetadata? found;
    OAuthError? lastError;
    for (final url in candidates) {
      try {
        found = await fetchProtectedResourceMetadata(url);
        break;
      } on OAuthError catch (e) {
        lastError = e;
      }
    }
    final prm = found ?? (throw lastError!);
    if (prm.resource.isNotEmpty) _resource = canonicalResourceUri(prm.resource);
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
    // PKCE support is read from the metadata; without it there is no flow.
    if (!(metadata.codeChallengeMethodsSupported ?? const []).contains('S256')) {
      throw OAuthError(
        error: 'pkce_unsupported',
        errorDescription: '${metadata.issuer} does not advertise PKCE with S256; refusing to proceed',
      );
    }
    final pkce = _generatePkce();

    // Store code verifier for later use
    _codeVerifier = pkce['code_verifier']!;
    _state = state ?? _generateState();

    final params = <String, String>{
      'response_type': 'code',
      'client_id': effectiveClientId,
      'code_challenge': pkce['code_challenge']!,
      'code_challenge_method': 'S256',
      if (config.redirectUri != null) 'redirect_uri': config.redirectUri!,
      if (scopes.isNotEmpty) 'scope': scopes.join(' '),
      'state': _state!,
      if (resource != null) 'resource': resource!,
      ...?additionalParams,
    };

    final uri = Uri.parse(
      metadata.authorizationEndpoint,
    ).replace(queryParameters: params);

    return uri.toString();
  }

  String? _codeVerifier;
  String? _state;

  /// Get the current code verifier for PKCE
  String? get codeVerifier => _codeVerifier;

  /// The `state` of the last authorization URL: the redirect must return it.
  String? get state => _state;

  /// Validate the `iss` parameter of an authorization response (RFC 9207,
  /// as MCP applies it): a present one must equal the issuer exactly; an
  /// absent one is refused when the server advertises
  /// `authorization_response_iss_parameter_supported`. Throws [OAuthError].
  Future<void> validateAuthorizationResponseIssuer(
      String? responseIssuer) async {
    final metadata = await _discoverMetadata();
    checkAuthorizationResponseIssuer(
      recordedIssuer: metadata.issuer,
      issParameterSupported: metadata.authorizationResponseIssParameterSupported,
      iss: responseIssuer,
    );
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
      if (resource != null) 'resource': resource!,
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
      if (resource != null) 'resource': resource!,
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
      if (resource != null) 'resource': resource!,
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
      if (resource != null) 'resource': resource!,
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

  /// Holds [token] in memory and schedules its refresh. Keeping tokens
  /// across restarts is [OAuthStore]'s job (see [McpOAuth]).
  Future<void> storeToken(OAuthToken token) async {
    _currentToken = token;
    _tokenController.add(token);
    _scheduleRefresh();
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
