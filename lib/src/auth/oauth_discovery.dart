/// MCP 2025-11-25 OAuth discovery primitives.
///
/// Additive layer over the existing OAuth 2.1 client: parses the
/// `WWW-Authenticate` challenge a Resource Server returns on a `401`
/// (RFC 9728 / SEP-985), models the OAuth Protected Resource Metadata
/// document, and drives authorization-server discovery via both RFC 8414 and
/// OpenID Connect Discovery 1.0 (PR#797). These are metadata *fetches* — no
/// cryptography is performed here; token acquisition reuses the existing
/// PKCE/token flow in [HttpOAuthClient].
library;

import 'package:meta/meta.dart';

/// A parsed `WWW-Authenticate: Bearer …` challenge (RFC 6750 / RFC 9728).
///
/// Only the `Bearer` scheme is interpreted. Recognized auth-params:
/// `resource_metadata` (RFC 9728 / SEP-985 — the PRM document URL),
/// `scope` (SEP-835 incremental scope step-up), `error`, `error_description`,
/// and `realm`. Unknown params are preserved in [params].
@immutable
class WwwAuthenticateChallenge {
  /// The challenge scheme (e.g. `Bearer`). Lower-cased for comparison.
  final String scheme;

  /// All auth-params as parsed (keys lower-cased, quotes stripped).
  final Map<String, String> params;

  const WwwAuthenticateChallenge({
    required this.scheme,
    required this.params,
  });

  /// RFC 9728 / SEP-985: URL of the OAuth Protected Resource Metadata
  /// document (`resource_metadata`), or null when absent.
  String? get resourceMetadata => params['resource_metadata'];

  /// SEP-835: space-delimited required scope advertised for step-up, or null.
  String? get scope => params['scope'];

  /// Parsed scope list (empty when [scope] is absent).
  List<String> get scopes {
    final s = scope;
    if (s == null || s.trim().isEmpty) return const [];
    return s.trim().split(RegExp(r'\s+'));
  }

  /// OAuth `error` code (e.g. `invalid_token`), or null.
  String? get error => params['error'];

  /// Human-readable `error_description`, or null.
  String? get errorDescription => params['error_description'];

  /// Whether this is a `Bearer` challenge.
  bool get isBearer => scheme == 'bearer';

  /// Parse a raw `WWW-Authenticate` header value.
  ///
  /// Tolerant of a single header carrying one challenge (the common MCP case:
  /// `Bearer resource_metadata="…", error="…", scope="…"`). Returns null when
  /// the value is empty. Non-Bearer schemes still parse (scheme captured) but
  /// carry whatever params are present.
  static WwwAuthenticateChallenge? parse(String? header) {
    if (header == null) return null;
    final trimmed = header.trim();
    if (trimmed.isEmpty) return null;

    // Split scheme from the auth-param list.
    final spaceIdx = trimmed.indexOf(' ');
    if (spaceIdx < 0) {
      return WwwAuthenticateChallenge(
        scheme: trimmed.toLowerCase(),
        params: const {},
      );
    }
    final scheme = trimmed.substring(0, spaceIdx).toLowerCase();
    final rest = trimmed.substring(spaceIdx + 1);

    return WwwAuthenticateChallenge(
      scheme: scheme,
      params: _parseAuthParams(rest),
    );
  }

  /// Parse the comma-separated `key=value` / `key="value"` auth-param list.
  ///
  /// Handles quoted values that themselves contain commas or `=` (e.g. a
  /// `resource_metadata` URL with a query string) by tracking quote state.
  static Map<String, String> _parseAuthParams(String input) {
    final result = <String, String>{};
    final buf = StringBuffer();
    final parts = <String>[];
    var inQuotes = false;

    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (ch == '"') {
        inQuotes = !inQuotes;
        buf.write(ch);
      } else if (ch == ',' && !inQuotes) {
        parts.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) parts.add(buf.toString());

    for (final part in parts) {
      final eq = part.indexOf('=');
      if (eq < 0) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      var value = part.substring(eq + 1).trim();
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      if (key.isNotEmpty) result[key] = value;
    }
    return result;
  }
}

/// OAuth 2.0 Protected Resource Metadata (RFC 9728), served at
/// `/.well-known/oauth-protected-resource` by a Resource Server.
@immutable
class ProtectedResourceMetadata {
  /// The protected resource's identifier (its canonical origin/URL).
  final String resource;

  /// Authorization servers that can issue tokens for this resource — the
  /// client OIDC/RFC-8414-discovers one of these to obtain a token.
  final List<String> authorizationServers;

  /// Scopes the resource server understands (advertised, not necessarily
  /// required per request).
  final List<String>? scopesSupported;

  /// Supported bearer token presentation methods (e.g. `header`).
  final List<String>? bearerMethodsSupported;

  /// Human-readable documentation URL.
  final String? resourceDocumentation;

  const ProtectedResourceMetadata({
    required this.resource,
    required this.authorizationServers,
    this.scopesSupported,
    this.bearerMethodsSupported,
    this.resourceDocumentation,
  });

  factory ProtectedResourceMetadata.fromJson(Map<String, dynamic> json) =>
      ProtectedResourceMetadata(
        resource: json['resource'] as String? ?? '',
        authorizationServers:
            (json['authorization_servers'] as List<dynamic>?)
                    ?.cast<String>() ??
                const [],
        scopesSupported:
            (json['scopes_supported'] as List<dynamic>?)?.cast<String>(),
        bearerMethodsSupported:
            (json['bearer_methods_supported'] as List<dynamic>?)
                ?.cast<String>(),
        resourceDocumentation: json['resource_documentation'] as String?,
      );

  /// The first advertised authorization server, or null when none.
  String? get primaryAuthorizationServer =>
      authorizationServers.isEmpty ? null : authorizationServers.first;
}
