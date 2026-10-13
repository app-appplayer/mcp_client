/// MCP authorization for a client (OAuth 2.1): discovery of the server's
/// authorization server, client registration, the authorization code flow
/// with PKCE, and the tokens it yields.
///
/// The flow has two halves because the middle belongs to the host: [begin]
/// produces the URL the user must visit and a [PendingAuthorization] to keep
/// until the authorization server redirects back; [complete] checks that
/// redirect and redeems the code. A host that can wait in-process (desktop,
/// CLI) gives [McpOAuthOptions.authorize] and lets [handleChallenge] run
/// both halves; a browser host stores the pending record across the page
/// navigation and calls [complete] when it returns.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../logger.dart';
import 'oauth.dart';
import 'oauth_discovery.dart';

final Logger _logger = Logger('mcp_client.oauth');

/// A client identity at one authorization server.
@immutable
class OAuthClientRegistration {
  const OAuthClientRegistration({required this.clientId, this.clientSecret});

  final String clientId;

  /// Present for confidential clients only.
  final String? clientSecret;

  Map<String, dynamic> toJson() => {
        'client_id': clientId,
        if (clientSecret != null) 'client_secret': clientSecret,
      };

  factory OAuthClientRegistration.fromJson(Map<String, dynamic> json) => OAuthClientRegistration(
        clientId: json['client_id'] as String,
        clientSecret: json['client_secret'] as String?,
      );
}

/// What a client holds for one MCP server: the token and where it came from.
@immutable
class OAuthGrant {
  const OAuthGrant({
    required this.issuer,
    required this.resource,
    required this.tokenEndpoint,
    required this.clientId,
    required this.token,
    required this.scopes,
  });

  /// The authorization server that issued [token].
  final String issuer;

  /// The canonical URI of the MCP server the token is for.
  final String resource;
  final String tokenEndpoint;
  final String clientId;
  final OAuthToken token;

  /// The scopes asked for (the token's own `scope` when it reports one).
  final List<String> scopes;

  Map<String, dynamic> toJson() => {
        'issuer': issuer,
        'resource': resource,
        'token_endpoint': tokenEndpoint,
        'client_id': clientId,
        'token': token.toJson(),
        'scopes': scopes,
      };

  factory OAuthGrant.fromJson(Map<String, dynamic> json) => OAuthGrant(
        issuer: json['issuer'] as String,
        resource: json['resource'] as String,
        tokenEndpoint: json['token_endpoint'] as String,
        clientId: json['client_id'] as String,
        token: OAuthToken.fromJson(Map<String, dynamic>.from(json['token'] as Map)),
        scopes: [for (final s in json['scopes'] as List) '$s'],
      );
}

/// Where client registrations and grants live. Registrations are keyed by
/// the issuing authorization server, grants by the MCP server.
///
/// The default keeps them in memory. Refresh tokens must stay confidential
/// at rest, so a host that persists them implements this over its
/// platform's secure storage.
abstract class OAuthStore {
  Future<OAuthClientRegistration?> loadClient(String issuer);
  Future<void> saveClient(String issuer, OAuthClientRegistration registration);
  Future<OAuthGrant?> loadGrant(String resource);
  Future<void> saveGrant(OAuthGrant grant);
  Future<void> deleteGrant(String resource);
}

/// [OAuthStore] in memory.
class MemoryOAuthStore implements OAuthStore {
  final Map<String, OAuthClientRegistration> _clients = {};
  final Map<String, OAuthGrant> _grants = {};

  @override
  Future<OAuthClientRegistration?> loadClient(String issuer) async => _clients[issuer];

  @override
  Future<void> saveClient(String issuer, OAuthClientRegistration registration) async =>
      _clients[issuer] = registration;

  @override
  Future<OAuthGrant?> loadGrant(String resource) async => _grants[resource];

  @override
  Future<void> saveGrant(OAuthGrant grant) async => _grants[grant.resource] = grant;

  @override
  Future<void> deleteGrant(String resource) async => _grants.remove(resource);
}

/// How this client identifies itself and reaches the user.
class McpOAuthOptions {
  McpOAuthOptions({
    required this.redirectUri,
    this.clientName = 'MCP client',
    this.clientIdMetadataUrl,
    this.preRegistered = const {},
    OAuthStore? store,
    this.authorize,
    this.applicationType,
    this.maxStepUps = 2,
  }) : store = store ?? MemoryOAuthStore() {
    final redirect = Uri.parse(redirectUri);
    if (!(redirect.scheme == 'https' || (redirect.scheme == 'http' && _isLoopback(redirect)))) {
      throw ArgumentError.value(redirectUri, 'redirectUri', 'must be https or a localhost URL');
    }
    final cimd = clientIdMetadataUrl;
    if (cimd != null) {
      final u = Uri.parse(cimd);
      if (u.scheme != 'https' || u.path.isEmpty || u.path == '/') {
        throw ArgumentError.value(cimd, 'clientIdMetadataUrl', 'must be an https URL with a path');
      }
    }
  }

  /// Where the authorization server sends the user back.
  final String redirectUri;

  /// The name shown at registration.
  final String clientName;

  /// This client's Client ID Metadata Document: an https URL with a path
  /// whose document's `client_id` is exactly this URL.
  final String? clientIdMetadataUrl;

  /// Client identities issued in advance, keyed by authorization server
  /// issuer. Used only with the issuer that issued them.
  final Map<String, OAuthClientRegistration> preRegistered;
  final OAuthStore store;

  /// Shows the user [url] and returns the redirect it ends at (desktop,
  /// mobile and CLI hosts). Null: the host drives [McpOAuth.begin] and
  /// [McpOAuth.complete] itself.
  final Future<Uri> Function(Uri url)? authorize;

  /// `native` or `web` for Dynamic Client Registration; derived from
  /// [redirectUri] when null (a loopback redirect is a native app).
  final String? applicationType;

  /// How many times one resource may ask for more scope before the failure
  /// is treated as permanent.
  final int maxStepUps;
}

/// An authorization request on its way to the authorization server: what
/// the client must keep to judge the answer. Encode it to survive a page
/// navigation; it holds the PKCE verifier, so keep it only for the session.
@immutable
class PendingAuthorization {
  const PendingAuthorization({
    required this.resource,
    required this.issuer,
    required this.issParameterSupported,
    required this.tokenEndpoint,
    required this.clientId,
    required this.redirectUri,
    required this.state,
    required this.codeVerifier,
    required this.scopes,
  });

  final String resource;

  /// The issuer of the validated metadata, recorded before the redirect.
  final String issuer;
  final bool issParameterSupported;
  final String tokenEndpoint;
  final String clientId;
  final String redirectUri;
  final String state;
  final String codeVerifier;
  final List<String> scopes;

  String encode() => jsonEncode({
        'resource': resource,
        'issuer': issuer,
        'iss_supported': issParameterSupported,
        'token_endpoint': tokenEndpoint,
        'client_id': clientId,
        'redirect_uri': redirectUri,
        'state': state,
        'code_verifier': codeVerifier,
        'scopes': scopes,
      });

  /// The record [encode] wrote, or null when [raw] is not one.
  static PendingAuthorization? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return PendingAuthorization(
        resource: j['resource'] as String,
        issuer: j['issuer'] as String,
        issParameterSupported: j['iss_supported'] as bool,
        tokenEndpoint: j['token_endpoint'] as String,
        clientId: j['client_id'] as String,
        redirectUri: j['redirect_uri'] as String,
        state: j['state'] as String,
        codeVerifier: j['code_verifier'] as String,
        scopes: [for (final s in j['scopes'] as List) '$s'],
      );
    } on Object {
      return null;
    }
  }
}

/// The canonical URI of an MCP server (RFC 8707 resource indicator):
/// lower-case scheme and host, no fragment, no trailing slash.
String canonicalResourceUri(String url) {
  final u = Uri.parse(url);
  if (!u.hasScheme || !u.hasAuthority) {
    throw ArgumentError.value(url, 'url', 'is not an absolute URI');
  }
  var path = u.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final port = u.hasPort ? ':${u.port}' : '';
  return '${u.scheme.toLowerCase()}://${u.host.toLowerCase()}$port$path${u.hasQuery ? '?${u.query}' : ''}';
}

/// Where the Protected Resource Metadata of [serverUrl] may be, in the order
/// to try: at the server's path, then at the root (RFC 9728 §3.1).
List<Uri> protectedResourceMetadataUrls(String serverUrl) {
  final u = Uri.parse(serverUrl);
  const wellKnown = '/.well-known/oauth-protected-resource';
  final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  return [
    if (path.isNotEmpty) u.replace(path: '$wellKnown$path', query: null, fragment: null),
    u.replace(path: wellKnown, query: null, fragment: null),
  ];
}

/// Where the metadata of the authorization server [issuer] may be, in the
/// order to try (RFC 8414 §3.1 with OpenID Connect Discovery).
List<Uri> authorizationServerMetadataUrls(String issuer) {
  final u = Uri.parse(issuer);
  final path = u.path.endsWith('/') ? u.path.substring(0, u.path.length - 1) : u.path;
  Uri at(String p) => u.replace(path: p, query: null, fragment: null);
  if (path.isEmpty) {
    return [at('/.well-known/oauth-authorization-server'), at('/.well-known/openid-configuration')];
  }
  return [
    at('/.well-known/oauth-authorization-server$path'),
    at('/.well-known/openid-configuration$path'),
    at('$path/.well-known/openid-configuration'),
  ];
}

/// RFC 9207 §2.4 as MCP applies it: a present `iss` must equal the recorded
/// issuer exactly (no normalization); an absent one is refused only when
/// the server said it sends one. Throws [OAuthError] otherwise.
void checkAuthorizationResponseIssuer({
  required String recordedIssuer,
  required bool issParameterSupported,
  required String? iss,
}) {
  if (iss == null) {
    if (issParameterSupported) {
      throw const OAuthError(
          error: 'invalid_issuer', errorDescription: 'The authorization response carries no iss');
    }
    return;
  }
  if (iss != recordedIssuer) {
    throw OAuthError(
        error: 'invalid_issuer',
        errorDescription: 'The authorization response came from $iss, not $recordedIssuer');
  }
}

bool _isLoopback(Uri u) => u.host == 'localhost' || u.host == '127.0.0.1' || u.host == '::1' || u.host == '[::1]';

/// One client's authorization with the MCP servers it talks to.
class McpOAuth {
  McpOAuth(this.options, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final McpOAuthOptions options;
  final http.Client _http;
  final Random _random = Random.secure();

  /// Step-ups per resource and scope set, to stop asking for ever.
  final Map<String, int> _stepUps = {};

  /// One authorization at a time per resource: concurrent 401s share it.
  final Map<String, Future<bool>> _running = {};

  /// The access token for [serverUrl], refreshed when it has expired; null
  /// when there is none (the server's 401 starts an authorization).
  Future<String?> accessToken(String serverUrl) async {
    final resource = canonicalResourceUri(serverUrl);
    final grant = await options.store.loadGrant(resource);
    if (grant == null) return null;
    if (!grant.token.isExpired) return grant.token.accessToken;
    final refresh = grant.token.refreshToken;
    if (refresh == null) return null;
    try {
      return (await _refresh(grant, refresh)).token.accessToken;
    } on OAuthError catch (e) {
      _logger.warning('Refreshing the token for $resource failed: $e');
      await options.store.deleteGrant(resource);
      return null;
    }
  }

  /// Answer a 401 or 403 from [serverUrl]: authorize (or step up) through
  /// [McpOAuthOptions.authorize]. True when there is a new token to retry
  /// with; false when this client cannot (no `authorize`, or step-ups spent).
  Future<bool> handleChallenge({
    required String serverUrl,
    required int status,
    String? wwwAuthenticate,
  }) {
    final resource = canonicalResourceUri(serverUrl);
    // The callback must not return the removed future: whenComplete would
    // then wait on the very future it completes.
    return _running[resource] ??= _handle(serverUrl, status, wwwAuthenticate).whenComplete(() {
      _running.remove(resource);
    });
  }

  Future<bool> _handle(String serverUrl, int status, String? wwwAuthenticate) async {
    final authorize = options.authorize;
    if (authorize == null) return false;
    final challenge = WwwAuthenticateChallenge.parse(wwwAuthenticate);
    final resource = canonicalResourceUri(serverUrl);
    var keep = const <String>[];
    if (status == 403) {
      if (challenge?.error != 'insufficient_scope') return false;
      final previous = await options.store.loadGrant(resource);
      keep = previous?.scopes ?? const [];
      final key = '$resource ${{...keep, ...challenge!.scopes}.toList()..sort()}';
      final tries = _stepUps[key] = (_stepUps[key] ?? 0) + 1;
      if (tries > options.maxStepUps) return false;
    }
    final started = await begin(serverUrl: serverUrl, wwwAuthenticate: wwwAuthenticate, keepScopes: keep);
    final redirect = await authorize(started.url);
    await complete(started.pending, redirect);
    return true;
  }

  /// The first half: discover, register, and build the authorization URL.
  /// [keepScopes] are scopes already held that a step-up must not lose.
  Future<({Uri url, PendingAuthorization pending})> begin({
    required String serverUrl,
    String? wwwAuthenticate,
    List<String> keepScopes = const [],
  }) async {
    final resourceUrl = canonicalResourceUri(serverUrl);
    final challenge = WwwAuthenticateChallenge.parse(wwwAuthenticate);
    final prm = await _protectedResource(serverUrl, challenge);
    final resource = prm == null ? resourceUrl : canonicalResourceUri(prm.resource);
    final metadata = prm == null
        ? await _legacyAuthorizationServer(serverUrl)
        : await authorizationServerMetadata(_chooseAuthorizationServer(prm));
    _requirePkce(metadata);
    _requireHttps(metadata);

    // A token from a different authorization server is never sent again.
    final held = await options.store.loadGrant(resource);
    if (held != null && held.issuer != metadata.issuer) {
      _logger.warning('The authorization server of $resource changed (${held.issuer} -> ${metadata.issuer})');
      await options.store.deleteGrant(resource);
    }

    final registration = await _registration(metadata);
    final scopes = {
      ...keepScopes,
      ...(challenge?.scopes.isNotEmpty ?? false) ? challenge!.scopes : (prm?.scopesSupported ?? const <String>[]),
    }.toList();
    final verifier = _randomToken(32);
    final state = _randomToken(16);
    final url = Uri.parse(metadata.authorizationEndpoint).replace(queryParameters: {
      ...Uri.parse(metadata.authorizationEndpoint).queryParameters,
      'response_type': 'code',
      'client_id': registration.clientId,
      'redirect_uri': options.redirectUri,
      'code_challenge': base64Url.encode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', ''),
      'code_challenge_method': 'S256',
      'state': state,
      'resource': resource,
      if (scopes.isNotEmpty) 'scope': scopes.join(' '),
    });
    return (
      url: url,
      pending: PendingAuthorization(
        resource: resource,
        issuer: metadata.issuer,
        issParameterSupported: metadata.authorizationResponseIssParameterSupported,
        tokenEndpoint: metadata.tokenEndpoint,
        clientId: registration.clientId,
        redirectUri: options.redirectUri,
        state: state,
        codeVerifier: verifier,
        scopes: scopes,
      ),
    );
  }

  /// The second half: judge the redirect the authorization server sent
  /// back and redeem its code. The issuer is checked first, then `state`;
  /// an `error` is reported only once both hold.
  Future<OAuthGrant> complete(PendingAuthorization pending, Uri redirect) async {
    final params = redirect.queryParameters;
    checkAuthorizationResponseIssuer(
      recordedIssuer: pending.issuer,
      issParameterSupported: pending.issParameterSupported,
      iss: params['iss'],
    );
    if (params['state'] != pending.state) {
      throw const OAuthError(
          error: 'invalid_state', errorDescription: 'The answer is not for the request this client made');
    }
    final error = params['error'];
    if (error != null) {
      throw OAuthError(error: error, errorDescription: params['error_description'], errorUri: params['error_uri']);
    }
    final code = params['code'];
    if (code == null) {
      throw const OAuthError(error: 'invalid_request', errorDescription: 'The answer carries no code');
    }
    final registration = await _knownRegistration(pending.issuer, pending.clientId);
    final token = await _tokenRequest(pending.tokenEndpoint, registration, {
      'grant_type': 'authorization_code',
      'code': code,
      'redirect_uri': pending.redirectUri,
      'code_verifier': pending.codeVerifier,
      'resource': pending.resource,
    });
    final grant = OAuthGrant(
      issuer: pending.issuer,
      resource: pending.resource,
      tokenEndpoint: pending.tokenEndpoint,
      clientId: pending.clientId,
      token: token,
      scopes: token.scopes ?? pending.scopes,
    );
    await options.store.saveGrant(grant);
    return grant;
  }

  /// The authorization server's metadata: tried at each well-known
  /// location in turn; the document must name [issuer] exactly.
  Future<AuthServerMetadata> authorizationServerMetadata(String issuer) async {
    for (final url in authorizationServerMetadataUrls(issuer)) {
      final json = await _getJson(url);
      if (json == null) continue;
      if (json['issuer'] != issuer) {
        throw OAuthError(
            error: 'invalid_issuer',
            errorDescription: 'Metadata at $url names issuer ${json['issuer']}, not $issuer');
      }
      return AuthServerMetadata.fromJson(json);
    }
    throw OAuthError(error: 'as_discovery_failed', errorDescription: 'No metadata for the authorization server $issuer');
  }

  Future<ProtectedResourceMetadata?> _protectedResource(String serverUrl, WwwAuthenticateChallenge? challenge) async {
    final announced = challenge?.resourceMetadata;
    final candidates = announced != null ? [Uri.parse(announced)] : protectedResourceMetadataUrls(serverUrl);
    for (final url in candidates) {
      final json = await _getJson(url);
      if (json == null) continue;
      final prm = ProtectedResourceMetadata.fromJson(json);
      if (prm.resource.isEmpty || !_covers(prm.resource, serverUrl)) {
        throw OAuthError(
            error: 'invalid_resource',
            errorDescription: 'Metadata at $url describes ${prm.resource}, not $serverUrl');
      }
      if (prm.authorizationServers.isEmpty) {
        throw OAuthError(error: 'no_authorization_server', errorDescription: 'Metadata at $url names no authorization server');
      }
      return prm;
    }
    if (announced != null) {
      throw OAuthError(error: 'protected_resource_discovery_failed', errorDescription: 'No metadata at $announced');
    }
    return null; // a 2025-03-26 server: no protected resource metadata
  }

  /// Whether a resource identifier covers [serverUrl]: same origin, and the
  /// server's path at or under the resource's.
  static bool _covers(String resource, String serverUrl) {
    final r = Uri.parse(canonicalResourceUri(resource));
    final s = Uri.parse(canonicalResourceUri(serverUrl));
    if (r.origin != s.origin) return false;
    return s.path == r.path || r.path.isEmpty || s.path.startsWith('${r.path}/');
  }

  String _chooseAuthorizationServer(ProtectedResourceMetadata prm) => prm.authorizationServers.first;

  /// 2025-03-26: the authorization server is at the server's origin, its
  /// metadata at the origin's well-known URI, otherwise the default paths.
  Future<AuthServerMetadata> _legacyAuthorizationServer(String serverUrl) async {
    final origin = Uri.parse(serverUrl).origin;
    final json = await _getJson(Uri.parse('$origin/.well-known/oauth-authorization-server'));
    if (json != null) return AuthServerMetadata.fromJson(json);
    return AuthServerMetadata(
      issuer: origin,
      authorizationEndpoint: '$origin/authorize',
      tokenEndpoint: '$origin/token',
      registrationEndpoint: '$origin/register',
      codeChallengeMethodsSupported: const ['S256'], // PKCE is required of every 2025-03-26 server
    );
  }

  void _requirePkce(AuthServerMetadata metadata) {
    final methods = metadata.codeChallengeMethodsSupported;
    if (methods == null || !methods.contains('S256')) {
      throw OAuthError(
          error: 'pkce_unsupported',
          errorDescription: '${metadata.issuer} does not advertise PKCE with S256; refusing to proceed');
    }
  }

  void _requireHttps(AuthServerMetadata metadata) {
    for (final endpoint in [metadata.authorizationEndpoint, metadata.tokenEndpoint, metadata.registrationEndpoint]) {
      if (endpoint == null) continue;
      final u = Uri.parse(endpoint);
      if (u.scheme != 'https' && !(u.scheme == 'http' && _isLoopback(u))) {
        throw OAuthError(error: 'insecure_endpoint', errorDescription: '$endpoint is not https');
      }
    }
  }

  /// The client identity to use at [metadata]'s server: one issued in
  /// advance or registered earlier with this issuer, else this client's
  /// metadata document when the server accepts those, else a new
  /// registration.
  Future<OAuthClientRegistration> _registration(AuthServerMetadata metadata) async {
    final issuer = metadata.issuer;
    final known = options.preRegistered[issuer] ?? await options.store.loadClient(issuer);
    if (known != null) return known;
    if (options.preRegistered.isNotEmpty) {
      _logger.warning('No pre-registered client for $issuer; the ones held are for other servers');
    }
    final cimd = options.clientIdMetadataUrl;
    if (cimd != null && metadata.clientIdMetadataDocumentSupported) {
      return OAuthClientRegistration(clientId: cimd);
    }
    final endpoint = metadata.registrationEndpoint;
    if (endpoint == null) {
      throw OAuthError(
          error: 'no_client_registration',
          errorDescription: '$issuer offers no registration; configure a client issued by it');
    }
    final redirect = Uri.parse(options.redirectUri);
    final response = await _http.post(
      Uri.parse(endpoint),
      headers: {'Content-Type': 'application/json', 'Accept': 'application/json'},
      body: jsonEncode({
        'client_name': options.clientName,
        'redirect_uris': [options.redirectUri],
        'grant_types': ['authorization_code', 'refresh_token'],
        'response_types': ['code'],
        'token_endpoint_auth_method': 'none',
        'application_type': options.applicationType ?? (_isLoopback(redirect) ? 'native' : 'web'),
      }),
    );
    final json = _jsonObject(response.body);
    if (response.statusCode != 200 && response.statusCode != 201 || json?['client_id'] is! String) {
      throw OAuthError(
        error: json?['error'] as String? ?? 'registration_failed',
        errorDescription: 'Registration at $endpoint was refused (${response.statusCode})'
            '${json?['error_description'] != null ? ': ${json!['error_description']}' : ''}',
      );
    }
    final registration = OAuthClientRegistration.fromJson(json!);
    await options.store.saveClient(issuer, registration);
    return registration;
  }

  Future<OAuthClientRegistration> _knownRegistration(String issuer, String clientId) async {
    final known = options.preRegistered[issuer] ?? await options.store.loadClient(issuer);
    if (known != null && known.clientId == clientId) return known;
    return OAuthClientRegistration(clientId: clientId);
  }

  Future<OAuthGrant> _refresh(OAuthGrant grant, String refreshToken) async {
    final registration = await _knownRegistration(grant.issuer, grant.clientId);
    final token = await _tokenRequest(grant.tokenEndpoint, registration, {
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'resource': grant.resource,
    });
    final next = OAuthGrant(
      issuer: grant.issuer,
      resource: grant.resource,
      tokenEndpoint: grant.tokenEndpoint,
      clientId: grant.clientId,
      // A server that does not rotate the refresh token leaves the old one valid.
      token: token.refreshToken != null
          ? token
          : OAuthToken(
              accessToken: token.accessToken,
              tokenType: token.tokenType,
              expiresIn: token.expiresIn,
              refreshToken: refreshToken,
              scopes: token.scopes,
              issuedAt: token.issuedAt,
              extra: token.extra,
            ),
      scopes: token.scopes ?? grant.scopes,
    );
    await options.store.saveGrant(next);
    return next;
  }

  Future<OAuthToken> _tokenRequest(
      String endpoint, OAuthClientRegistration registration, Map<String, String> form) async {
    final headers = {'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json'};
    final secret = registration.clientSecret;
    if (secret != null) {
      headers['Authorization'] = 'Basic ${base64Encode(utf8.encode(
          '${Uri.encodeQueryComponent(registration.clientId)}:${Uri.encodeQueryComponent(secret)}'))}';
    } else {
      form = {...form, 'client_id': registration.clientId};
    }
    final response = await _http.post(Uri.parse(endpoint), headers: headers, body: form);
    final json = _jsonObject(response.body);
    if (response.statusCode != 200 || json == null || json['access_token'] is! String) {
      throw json != null && json['error'] is String
          ? OAuthError.fromJson(json)
          : OAuthError(error: 'token_request_failed', errorDescription: 'Token endpoint answered ${response.statusCode}');
    }
    return OAuthToken.fromJson(json);
  }

  Future<Map<String, dynamic>?> _getJson(Uri url) async {
    try {
      final response = await _http.get(url, headers: {'Accept': 'application/json'});
      if (response.statusCode != 200) return null;
      return _jsonObject(response.body);
    } on Object catch (e) {
      _logger.debug('GET $url failed: $e');
      return null;
    }
  }

  static Map<String, dynamic>? _jsonObject(String body) {
    try {
      final v = jsonDecode(body);
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }

  String _randomToken(int bytes) =>
      base64Url.encode(List<int>.generate(bytes, (_) => _random.nextInt(256))).replaceAll('=', '');

  void close() => _http.close();
}
