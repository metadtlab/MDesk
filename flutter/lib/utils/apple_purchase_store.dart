import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

enum AppleStorePurchaseStatus { pending, purchased, restored, canceled, error }

/// Store-facing data only. Entitlements must be granted by the billing server.
class AppleStoreProduct {
  const AppleStoreProduct({
    required this.id,
    required this.title,
    required this.description,
    required this.price,
    required this.currencyCode,
    this.subscriptionPeriod,
    this.nativeProduct,
  });

  final String id;
  final String title;
  final String description;
  final String price;
  final String currencyCode;

  /// Only a one-month or one-year StoreKit auto-renewable subscription.
  /// Unsupported periods and non-subscription products are represented by null.
  final String? subscriptionPeriod;
  final Object? nativeProduct;
}

class AppleProductQuery {
  const AppleProductQuery({required this.products, required this.notFoundIds});

  final List<AppleStoreProduct> products;
  final Set<String> notFoundIds;
}

class AppleStorePurchase {
  const AppleStorePurchase({
    required this.status,
    required this.productId,
    required this.transactionId,
    required this.signedTransactionInfo,
    required this.appAccountToken,
    required this.pendingComplete,
    this.errorMessage,
    this.nativePurchase,
  });

  final AppleStorePurchaseStatus status;
  final String productId;
  final String? transactionId;

  /// Sensitive signed data: send to the server, never log or show in the UI.
  /// Its presence does not establish that a transaction is valid.
  final String signedTransactionInfo;
  final String? appAccountToken;
  final bool pendingComplete;
  final String? errorMessage;
  final Object? nativePurchase;
}

abstract class ApplePurchaseStore {
  Stream<List<AppleStorePurchase>> get purchases;
  Future<bool> isAvailable();
  Future<AppleProductQuery> queryProducts(Set<String> ids);
  Future<bool> buy(AppleStoreProduct product, String appAccountToken);
  Future<void> restore(String appAccountToken, {bool synchronize = false});
  Future<void> complete(AppleStorePurchase purchase);
}

/// Never includes a platform exception, receipt, signed transaction or account.
class ApplePurchaseStoreException implements Exception {
  const ApplePurchaseStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

const _unavailableMessage = '앱스토어에 연결할 수 없습니다. 잠시 후 다시 시도해 주세요.';
const _queryMessage = '앱스토어 상품 정보를 불러오지 못했습니다. 다시 시도해 주세요.';
const _purchaseMessage = '앱스토어 결제를 시작하지 못했습니다. 다시 시도해 주세요.';
const _restoreSyncMessage =
    '앱스토어 구매 내역을 동기화하지 못했습니다. 인증 및 연결 상태를 확인하고 다시 시도해 주세요.';
const _restoreMessage = '앱스토어 구매 내역의 복원 확인을 완료하지 못했습니다. 잠시 후 다시 시도해 주세요.';
const _completeMessage = '앱스토어 거래 완료 처리를 하지 못했습니다. 다시 시도해 주세요.';
const _transactionMessage = '앱스토어 거래 정보를 확인하지 못했습니다. 다시 시도해 주세요.';
const _unsupportedMessage = '이 앱에서 지원하지 않는 앱스토어 상품 또는 거래입니다.';
const _accountMessage = '결제 계정 정보를 확인하지 못했습니다. 다시 로그인해 주세요.';

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _transactionIdPattern = RegExp(r'^[0-9]+$');

ApplePurchaseStoreException _restoreStageException(
  Object error, {
  required bool synchronizing,
}) {
  // Only fixed labels reach the UI. Native messages/details may contain account
  // information or signed transactions; even unknown native codes stay private.
  final stage = synchronizing ? 'SYNC' : 'RESTORE';
  var diagnostic = 'UNKNOWN';
  if (error is MissingPluginException) {
    diagnostic = 'PLUGIN';
  } else if (error is PlatformException) {
    diagnostic = switch (error.code) {
      'storekit2_failed_to_sync_to_app_store' when synchronizing => 'STORE',
      'storekit2_restore_failed' when !synchronizing => 'VERIFY',
      'channel-error' => 'CHANNEL',
      _ => 'UNKNOWN',
    };
  }
  final message = synchronizing ? _restoreSyncMessage : _restoreMessage;
  return ApplePurchaseStoreException('$message [IAP-$stage-$diagnostic]');
}

/// Thin StoreKit 2 adapter. The controller owns account binding and verification.
class InAppApplePurchaseStore implements ApplePurchaseStore {
  InAppApplePurchaseStore({
    InAppPurchase? inAppPurchase,
    Future<void> Function()? synchronizePurchases,
  })  : _inAppPurchase = inAppPurchase ?? InAppPurchase.instance,
        _synchronizePurchases = synchronizePurchases ?? AppStore().sync;

  final InAppPurchase _inAppPurchase;
  final Future<void> Function() _synchronizePurchases;

  @override
  Stream<List<AppleStorePurchase>> get purchases {
    try {
      return _inAppPurchase.purchaseStream
          .map((items) => List<AppleStorePurchase>.unmodifiable(
              items.map(mapAppleStorePurchase)))
          .transform(StreamTransformer<List<AppleStorePurchase>,
              List<AppleStorePurchase>>.fromHandlers(
        handleError: (error, stackTrace, sink) {
          sink.addError(const ApplePurchaseStoreException(_transactionMessage));
        },
      ));
    } catch (_) {
      return Stream.error(
          const ApplePurchaseStoreException(_transactionMessage));
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return await _inAppPurchase.isAvailable();
    } catch (_) {
      throw const ApplePurchaseStoreException(_unavailableMessage);
    }
  }

  @override
  Future<AppleProductQuery> queryProducts(Set<String> ids) async {
    if (ids.isEmpty) {
      return const AppleProductQuery(products: [], notFoundIds: {});
    }
    try {
      final response = await _inAppPurchase.queryProductDetails(ids);
      if (response.error != null) {
        throw const ApplePurchaseStoreException(_queryMessage);
      }
      final products = response.productDetails
          .where((product) => ids.contains(product.id))
          .map(mapAppleStoreProduct)
          .toList(growable: false);
      return AppleProductQuery(
        products: List<AppleStoreProduct>.unmodifiable(products),
        notFoundIds: Set<String>.unmodifiable(
          ids.difference(products.map((product) => product.id).toSet()),
        ),
      );
    } catch (_) {
      throw const ApplePurchaseStoreException(_queryMessage);
    }
  }

  @override
  Future<bool> buy(AppleStoreProduct product, String appAccountToken) async {
    _requireAccountToken(appAccountToken);
    final native = product.nativeProduct;
    if (native is! AppStoreProduct2Details ||
        native.id != product.id ||
        _subscriptionPeriod(native) == null ||
        _subscriptionPeriod(native) != product.subscriptionPeriod) {
      throw const ApplePurchaseStoreException(_unsupportedMessage);
    }
    try {
      return await _inAppPurchase.buyNonConsumable(
        purchaseParam: Sk2PurchaseParam(
          productDetails: native,
          applicationUserName: appAccountToken,
        ),
      );
    } catch (_) {
      throw const ApplePurchaseStoreException(_purchaseMessage);
    }
  }

  @override
  Future<void> restore(String appAccountToken,
      {bool synchronize = false}) async {
    _requireAccountToken(appAccountToken);
    if (synchronize) {
      try {
        // Force synchronization only for an explicit missing-purchase action.
        // AppStore.sync can require Apple authentication. Ordinary restoration
        // reads verified currentEntitlements without this extra prerequisite.
        await _synchronizePurchases();
      } catch (error) {
        // A failed explicit force sync is not silently converted into success.
        throw _restoreStageException(error, synchronizing: true);
      }
    }
    try {
      // The StoreKit 2 plugin reads currentEntitlements and emits verified JWS
      // transactions. It does not filter by this account parameter; the server
      // must still verify every transaction and its MDesk account binding.
      await _inAppPurchase.restorePurchases(
          applicationUserName: appAccountToken);
    } catch (error) {
      throw _restoreStageException(error, synchronizing: false);
    }
  }

  @override
  Future<void> complete(AppleStorePurchase purchase) async {
    if (!purchase.pendingComplete) return;
    final native = purchase.nativePurchase;
    if (native is! PurchaseDetails ||
        native.productID != purchase.productId ||
        native.purchaseID != purchase.transactionId ||
        native.status == PurchaseStatus.pending) {
      throw const ApplePurchaseStoreException(_completeMessage);
    }
    if (!native.pendingCompletePurchase) return;
    try {
      await _inAppPurchase.completePurchase(native);
    } catch (_) {
      throw const ApplePurchaseStoreException(_completeMessage);
    }
  }

  static void _requireAccountToken(String token) {
    if (!_uuidPattern.hasMatch(token)) {
      throw const ApplePurchaseStoreException(_accountMessage);
    }
  }
}

@visibleForTesting
AppleStoreProduct mapAppleStoreProduct(ProductDetails product) {
  return AppleStoreProduct(
    id: product.id,
    title: product.title,
    description: product.description,
    price: product.price,
    currencyCode: product.currencyCode,
    subscriptionPeriod: _subscriptionPeriod(product),
    nativeProduct: product,
  );
}

String? _subscriptionPeriod(ProductDetails product) {
  if (product is! AppStoreProduct2Details ||
      product.sk2Product.type != SK2ProductType.autoRenewable) {
    return null;
  }
  final period = product.sk2Product.subscription?.subscriptionPeriod;
  if (period == null || period.value != 1) return null;
  switch (period.unit) {
    case SK2SubscriptionPeriodUnit.month:
      return 'month';
    case SK2SubscriptionPeriodUnit.year:
      return 'year';
    case SK2SubscriptionPeriodUnit.day:
    case SK2SubscriptionPeriodUnit.week:
      return null;
  }
}

@visibleForTesting
AppleStorePurchase mapAppleStorePurchase(PurchaseDetails purchase) {
  var status = switch (purchase.status) {
    PurchaseStatus.pending => AppleStorePurchaseStatus.pending,
    PurchaseStatus.purchased => AppleStorePurchaseStatus.purchased,
    PurchaseStatus.restored => AppleStorePurchaseStatus.restored,
    PurchaseStatus.canceled => AppleStorePurchaseStatus.canceled,
    PurchaseStatus.error => AppleStorePurchaseStatus.error,
  };
  var signedTransactionInfo = '';
  String? appAccountToken;
  String? errorMessage;
  if (status == AppleStorePurchaseStatus.purchased ||
      status == AppleStorePurchaseStatus.restored) {
    if (purchase is! SK2PurchaseDetails) {
      status = AppleStorePurchaseStatus.error;
      errorMessage = _unsupportedMessage;
    } else {
      final signed = purchase.verificationData.serverVerificationData;
      final segments = signed.split('.');
      final transactionId = purchase.purchaseID;
      if (purchase.verificationData.source != 'app_store' ||
          segments.length != 3 ||
          segments.any((segment) => segment.isEmpty) ||
          transactionId == null ||
          !_transactionIdPattern.hasMatch(transactionId)) {
        status = AppleStorePurchaseStatus.error;
        errorMessage = _transactionMessage;
      } else {
        // Shape checks only; cryptographic validation belongs to the server.
        signedTransactionInfo = signed;
        appAccountToken = purchase.appAccountToken;
      }
    }
  } else if (status == AppleStorePurchaseStatus.error) {
    // Platform error messages/details may contain signed transactions or PII.
    errorMessage = _transactionMessage;
  }
  return AppleStorePurchase(
    status: status,
    productId: purchase.productID,
    transactionId: purchase.purchaseID,
    signedTransactionInfo: signedTransactionInfo,
    appAccountToken: appAccountToken,
    pendingComplete: purchase.pendingCompletePurchase,
    errorMessage: errorMessage,
    nativePurchase: purchase,
  );
}
