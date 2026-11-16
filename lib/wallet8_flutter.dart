// SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
// SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
// SPDX-FileCopyrightText: Copyright Contributors to the Wallet8 Flutter SDK
// SPDX-License-Identifier: Apache-2.0

/// The Wallet8 Flutter SDK - the reusable wallet core.
///
/// Every wallet app (this vertical's reference app, bank8's branded
/// wallet, any vertical's) embeds these pieces:
///
/// - [WalletServices] - the BFF-proxied service client set (the holder
///   vault, the auth issuer) - every call through `Bff8ApiClient`
///   (the platform rule: no direct backend calls).
/// - [CredentialStore] - the vault model (list, store, resolve).
/// - [WalletOid4vci] - the issuance driver: scan an offer, authorize,
///   prove, store.
/// - [WalletOid4vp] - the presentation driver: scan a verifier request,
///   match the DCQL query, consent, present.
library;

import 'package:sentin8/sentin8.dart' show BffApiClient, ApiResponse;

/// Unwrap a BFF response to its JSON payload (the ApiResponse carries
/// the status + the envelope; the drivers read the data member).
Map<String, dynamic>? _dataOf(ApiResponse response) {
  if (!response.isSuccess) return null;
  return response.data;
}

/// The wallet's BFF-proxied service set.
class WalletServices {
  /// The holder vault client.
  final BffApiClient holder;

  WalletServices._(this.holder);

  /// Build the service set from the BFF base.
  static WalletServices create({
    required String bffBaseUrl,
    String? csrfToken,
  }) =>
      WalletServices._(
        BffApiClient(
          bffBaseUrl: bffBaseUrl,
          serviceName: 'wallet8-holder',
          csrfToken: csrfToken,
        ),
      );
}

/// One stored credential (the vault row view).
class StoredCredentialView {
  /// The row id.
  final String id;

  /// The display name.
  final String displayName;

  /// The format.
  final String format;

  /// The doctype (mdoc).
  final String? doctype;

  /// The issuer host.
  final String issuer;

  StoredCredentialView({
    required this.id,
    required this.displayName,
    required this.format,
    this.doctype,
    required this.issuer,
  });

  factory StoredCredentialView.fromJson(Map<String, dynamic> json) =>
      StoredCredentialView(
        id: json['id'] as String,
        displayName: (json['display_name'] ?? '') as String,
        format: (json['format'] ?? '') as String,
        doctype: json['doctype'] as String?,
        issuer: (json['issuer'] ?? '') as String,
      );
}

/// The credential store model.
class CredentialStore {
  final WalletServices _services;

  CredentialStore(this._services);

  /// List the vault rows.
  Future<List<StoredCredentialView>> list() async {
    final res = await _services.holder.get('/v1/credentials');
    final data = _dataOf(res);
    if (data != null && data['rows'] is List) {
      return (data['rows'] as List)
          .map((e) => StoredCredentialView.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    return const [];
  }

  /// Store a minted credential.
  Future<void> store({
    required String format,
    String? doctype,
    String? vct,
    required String displayName,
    required String issuer,
    required String credential,
  }) =>
      _services.holder.post('/v1/credentials', body: {
        'format': format,
        'doctype': doctype,
        'vct': vct,
        'display_name': displayName,
        'issuer': issuer,
        'credential': credential,
      });
}

/// The OID4VCI issuance driver (the wallet-side flow).
class WalletOid4vci {
  final CredentialStore _store;

  WalletOid4vci(this._store);

  /// The offer-landing intake: the scanned QR carries the issuer's
  /// credential-offer URL. The flow (the holder service's backend
  /// orchestration through the BFF proxy, where the Rust SDK runs):
  /// (1) resolve the offer (by value or by reference),
  /// (2) the authorize round (PAR push + the code exchange, or the
  ///     pre-authorized code direct exchange with the End-User's
  ///     tx_code),
  /// (3) the nonce pre-flight + the proof + the credential request,
  /// (4) the vault store (immediate or deferred-parked).
  ///
  /// The [onProgress] callback drives the UI states - the
  /// certification's browser automation reads the rendered states.
  /// A deferred answer returns a pending [IssuancePending] (poll via
  /// [pollDeferred]); an immediate answer returns the stored view.
  Future<Object> intakeOffer(
    Uri offerUrl, {
    void Function(String stage)? onProgress,
    String? txCode,
  }) async {
    onProgress?.call('resolving');
    final res = await _store._services.holder.post(
      '/v1/issuance/intake',
      body: {
        'offer_url': offerUrl.toString(),
        if (txCode != null) 'tx_code': txCode,
      },
    );
    final data = _dataOf(res);
    if (data != null) {
      if (data['status'] == 'deferred') {
        onProgress?.call('deferred');
        return IssuancePending.fromJson(data);
      }
      onProgress?.call('issued');
      return StoredCredentialView.fromJson(data);
    }
    throw StateError('issuance intake: unexpected response');
  }

  /// The deferred-issuance poll (§9): the parked transaction
  /// re-submits; a pending answer returns [IssuancePending], the
  /// terminal one the stored view.
  Future<Object> pollDeferred(String transactionId) async {
    final res = await _store._services.holder.post(
      '/v1/issuance/deferred',
      body: {'transaction_id': transactionId},
    );
    final data = _dataOf(res);
    if (data != null) {
      if (data['status'] == 'pending') {
        return IssuancePending.fromJson(data);
      }
      return StoredCredentialView.fromJson(data);
    }
    throw StateError('deferred poll: unexpected response');
  }

  /// The authorization-code round's first half (§3.4): the PAR push
  /// + the authorize URL - the app opens the browser round, the
  /// callback lands with code + state, [completeAuthorization]
  /// finishes.
  Future<PreparedIssuance> prepareAuthorization(Uri offerUrl) async {
    final res = await _store._services.holder.post(
      '/v1/issuance/prepare',
      body: {'offer_url': offerUrl.toString()},
    );
    final data = _dataOf(res);
    if (data != null) {
      return PreparedIssuance.fromJson(data);
    }
    throw StateError('issuance prepare: unexpected response');
  }

  /// The authorization-code round's second half (§3.4): the code
  /// exchange + the proof + the credential request + the vault
  /// store + the notification.
  Future<Object> completeAuthorization({
    required String session,
    required String code,
    required String state,
  }) async {
    final res = await _store._services.holder.post(
      '/v1/issuance/complete',
      body: {'session': session, 'code': code, 'state': state},
    );
    final data = _dataOf(res);
    if (data != null) {
      if (data['status'] == 'deferred') {
        return IssuancePending.fromJson(data);
      }
      return StoredCredentialView.fromJson(data);
    }
    throw StateError('issuance complete: unexpected response');
  }

  /// The vault's status walk (§11.6): the revocation check over
  /// every active SD-JWT VC; a revoked row stops presenting.
  Future<Map<String, int>> syncStatuses() async {
    final res = await _store._services.holder.post('/v1/credentials/sync');
    final data = _dataOf(res) ?? const <String, dynamic>{};
    return {
      'checked': (data['checked'] as num?)?.toInt() ?? 0,
      'revoked': (data['revoked'] as num?)?.toInt() ?? 0,
    };
  }
}

/// The OID4VP presentation driver.
class WalletOid4vp {
  final CredentialStore _store;

  WalletOid4vp(this._store);

  /// The verifier-request RESOLUTION (pre-consent): verify the
  /// request object (§5.9), match the DCQL query, and return the
  /// consent preview - the requested claims + the verifier identity
  /// the user sees BEFORE any disclosure (the certification's
  /// consent requirement; the negative modules read the error screen
  /// when the verification/parse/match fails).
  Future<ConsentPreview> resolveRequest(
    Uri requestUri, {
    String? origin,
  }) async {
    final res = await _store._services.holder.post(
      '/v1/presentation/resolve',
      body: {
        'request_uri': requestUri.toString(),
        if (origin != null) 'origin': origin,
      },
    );
    final data = _dataOf(res);
    if (data != null) {
      return ConsentPreview.fromJson(data);
    }
    throw StateError('presentation resolve: unexpected response');
  }

  /// The presentation (post-consent): assemble the vp_token for the
  /// user-approved claims and deliver it. The negative path (no
  /// matching credential / the user denied) returns the
  /// access_denied/invalid_request error - never an empty vp_token.
  /// The dc_api forms return the promise payload (the app resolves
  /// it; no back-channel); the direct_post forms return the
  /// redirect_url (the browser MUST open it - §8.2).
  Future<PresentationOutcome> present({
    required String session,
    required bool approved,
    String? origin,
  }) async {
    final res = await _store._services.holder.post(
      '/v1/presentation/present',
      body: {
        'session': session,
        'approved': approved,
        if (origin != null) 'origin': origin,
      },
    );
    final data = _dataOf(res);
    if (data != null) {
      return PresentationOutcome.fromJson(data);
    }
    throw StateError('presentation: unexpected response');
  }
}

/// The consent preview (the pre-disclosure surface).
class ConsentPreview {
  /// The resolve step's session key (the present step carries it).
  final String session;

  /// The verifier's full client_id.
  final String verifierClientId;

  /// The verifier's display host.
  final String verifierHost;

  /// The requested claims (per credential entry).
  final List<RequestedCredential> requested;

  /// The request's response mode (the UI hints at the channel).
  final String responseMode;

  ConsentPreview({
    required this.session,
    required this.verifierClientId,
    required this.verifierHost,
    required this.requested,
    required this.responseMode,
  });

  factory ConsentPreview.fromJson(Map<String, dynamic> json) => ConsentPreview(
        session: (json['session'] ?? '') as String,
        verifierClientId: (json['verifier_client_id'] ?? '') as String,
        verifierHost: (json['verifier_host'] ?? '') as String,
        responseMode: (json['response_mode'] ?? 'direct_post') as String,
        requested: (json['credentials'] as List<dynamic>? ?? [])
            .map((e) => RequestedCredential.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

/// One requested credential of the consent preview.
class RequestedCredential {
  /// The DCQL query id (the vp_token key).
  final String queryId;

  /// The format (mso_mdoc / dc+sd-jwt).
  final String format;

  /// The doctype or vct (display).
  final String? typeLabel;

  /// The claim paths the verifier requested.
  final List<String> claims;

  RequestedCredential({
    required this.queryId,
    required this.format,
    this.typeLabel,
    required this.claims,
  });

  factory RequestedCredential.fromJson(Map<String, dynamic> json) =>
      RequestedCredential(
        queryId: (json['query_id'] ?? '') as String,
        format: (json['format'] ?? '') as String,
        typeLabel: (json['doctype'] ?? json['vct']) as String?,
        claims: (json['claims'] as List<dynamic>? ?? [])
            .map((c) => c.toString())
            .toList(),
      );
}

/// The presentation's outcome (the success redirect or the error).
class PresentationOutcome {
  /// The verifier's redirect target (the success path - the browser
  /// MUST open this, not a back-channel).
  final String? redirectUrl;

  /// The error code (the negative path).
  final String? error;

  /// The error description (the visible error screen's text).
  final String? errorDescription;

  /// The full payload (the dc_api promise form - App. A.4).
  final Map<String, dynamic> data;

  PresentationOutcome({this.redirectUrl, this.error, this.errorDescription, this.data = const {}});

  factory PresentationOutcome.fromJson(Map<String, dynamic> json) =>
      PresentationOutcome(
        redirectUrl: (json['redirect_url'] ?? json['redirect_uri']) as String?,
        error: json['error'] as String?,
        errorDescription: json['error_description'] as String?,
        data: json,
      );
}

/// The deferred issuance's pending marker (§9).
class IssuancePending {
  /// The transaction id (the poll key).
  final String transactionId;

  /// The minimum wait (seconds).
  final int interval;

  IssuancePending({required this.transactionId, required this.interval});

  factory IssuancePending.fromJson(Map<String, dynamic> json) => IssuancePending(
        transactionId: (json['transaction_id'] ?? '') as String,
        interval: (json['interval'] as num?)?.toInt() ?? 0,
      );
}

/// The prepared authorization (§3.4's first half).
class PreparedIssuance {
  /// The session key (the complete step carries it back).
  final String session;

  /// The authorize URL (the browser round's entry).
  final String authorizeUrl;

  PreparedIssuance({required this.session, required this.authorizeUrl});

  factory PreparedIssuance.fromJson(Map<String, dynamic> json) => PreparedIssuance(
        session: (json['session'] ?? '') as String,
        authorizeUrl: (json['authorize_url'] ?? '') as String,
      );
}
