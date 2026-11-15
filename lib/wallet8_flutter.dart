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
    if (res is List) {
      return res
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
  /// credential-offer URL; the flow resolves the offer, authorizes,
  /// proves, and stores - the concrete steps run over the Rust SDK
  /// crates (wallet8::oid4vci) through the backend; this Dart layer
  /// drives the UI states.
  Future<void> intakeOffer(Uri offerUrl) async {
    // The driver's backend surface (the BFF proxy) - the concrete
    // step wiring lands with the holder service's presentation
    // endpoints (the OIDF-ISO-1 rig cells drive the exact shapes).
    throw UnimplementedError('intakeOffer: wired by the issuance flow');
  }
}

/// The OID4VP presentation driver.
class WalletOid4vp {
  final CredentialStore _store;

  WalletOid4vp(this._store);

  /// The verifier-request intake: the scanned QR carries the
  /// request_uri; the flow parses the request object, matches the
  /// DCQL query, shows the consent screen, presents, and records.
  Future<void> present(Uri requestUri) async {
    throw UnimplementedError('present: wired by the presentation flow');
  }
}
