import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_hbb/utils/apple_purchase_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

const _accountToken = '12345678-1234-1234-1234-123456789012';
const _signedTransaction = 'signed-header.signed-payload.signed-signature';
const _rawSecret = 'private-account-and-signed-transaction';

AppStoreProduct2Details _product({
  String id = 'com.metadtlab.mdesk.test.monthly',
  SK2ProductType type = SK2ProductType.autoRenewable,
  SK2SubscriptionPeriodUnit unit = SK2SubscriptionPeriodUnit.month,
  int value = 1,
  bool withSubscription = true,
}) {
  return AppStoreProduct2Details.fromSK2Product(SK2Product(
    id: id,
    displayName: 'MDesk test product',
    description: 'Remote support subscription',
    displayPrice: '₩9,900',
    price: 9900,
    type: type,
    priceLocale: SK2PriceLocale(currencyCode: 'KRW', currencySymbol: '₩'),
    subscription: withSubscription
        ? SK2SubscriptionInfo(
            subscriptionGroupID: 'test-group',
            promotionalOffers: [],
            subscriptionPeriod: SK2SubscriptionPeriod(value: value, unit: unit),
          )
        : null,
  ));
}

SK2PurchaseDetails _purchase({
  PurchaseStatus status = PurchaseStatus.purchased,
  String? transactionId = '1234567890123456789',
  String signedTransaction = _signedTransaction,
  String source = 'app_store',
  String? appAccountToken = _accountToken,
}) {
  return SK2PurchaseDetails(
    productID: 'com.metadtlab.mdesk.test.monthly',
    purchaseID: transactionId,
    verificationData: PurchaseVerificationData(
      localVerificationData: '{"private":"$_rawSecret"}',
      serverVerificationData: signedTransaction,
      source: source,
    ),
    transactionDate: '1700000000000',
    status: status,
    appAccountToken: appAccountToken,
    expirationDate: '1702000000000',
  );
}

class _FakeInAppPurchase implements InAppPurchase {
  final updates = StreamController<List<PurchaseDetails>>.broadcast();
  bool available = true;
  Object? availabilityError;
  Object? queryError;
  Object? buyError;
  Object? restoreError;
  Object? completeError;
  bool buyResult = true;
  int queries = 0;
  ProductDetailsResponse response = ProductDetailsResponse(
    productDetails: [],
    notFoundIDs: [],
  );
  Set<String>? queriedIds;
  PurchaseParam? lastPurchaseParam;
  String? lastRestoreAccount;
  final completed = <PurchaseDetails>[];
  final operations = <String>[];

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => updates.stream;

  @override
  Future<bool> isAvailable() async {
    if (availabilityError != null) throw availabilityError!;
    return available;
  }

  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async {
    queries++;
    queriedIds = ids;
    if (queryError != null) throw queryError!;
    return response;
  }

  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    lastPurchaseParam = purchaseParam;
    if (buyError != null) throw buyError!;
    return buyResult;
  }

  @override
  Future<void> restorePurchases({String? applicationUserName}) async {
    operations.add('restore');
    lastRestoreAccount = applicationUserName;
    if (restoreError != null) throw restoreError!;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {
    if (completeError != null) throw completeError!;
    completed.add(purchase);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Matcher get _safeError => isA<ApplePurchaseStoreException>().having(
      (error) => error.toString(),
      'safe message',
      isNot(contains(_rawSecret)),
    );

void main() {
  group('StoreKit product mapping', () {
    test('uses store-localized price and actual monthly subscription period',
        () {
      final native = _product();
      final mapped = mapAppleStoreProduct(native);
      expect(mapped.id, native.id);
      expect(mapped.title, native.title);
      expect(mapped.description, native.description);
      expect(mapped.price, '₩9,900');
      expect(mapped.currencyCode, 'KRW');
      expect(mapped.subscriptionPeriod, 'month');
      expect(mapped.nativeProduct, same(native));
    });

    test('maps a one-year subscription', () {
      final mapped =
          mapAppleStoreProduct(_product(unit: SK2SubscriptionPeriodUnit.year));
      expect(mapped.subscriptionPeriod, 'year');
    });

    test('does not relabel consumables or permanent purchases as subscriptions',
        () {
      for (final type in [
        SK2ProductType.consumable,
        SK2ProductType.nonConsumable,
        SK2ProductType.nonRenewable,
      ]) {
        expect(mapAppleStoreProduct(_product(type: type)).subscriptionPeriod,
            isNull);
      }
    });

    test('unsupported durations and missing subscription data fail closed', () {
      for (final native in [
        _product(value: 2),
        _product(unit: SK2SubscriptionPeriodUnit.day),
        _product(unit: SK2SubscriptionPeriodUnit.week),
        _product(withSubscription: false),
      ]) {
        expect(mapAppleStoreProduct(native).subscriptionPeriod, isNull);
      }
    });

    test('generic products cannot establish an Apple subscription period', () {
      final native = ProductDetails(
        id: 'generic',
        title: 'Generic',
        description: 'No StoreKit metadata',
        price: '₩9,900',
        rawPrice: 9900,
        currencyCode: 'KRW',
      );
      expect(mapAppleStoreProduct(native).subscriptionPeriod, isNull);
    });
  });

  group('StoreKit transaction mapping', () {
    test('passes signed transaction to the server without granting entitlement',
        () {
      final native = _purchase();
      final mapped = mapAppleStorePurchase(native);
      expect(mapped.status, AppleStorePurchaseStatus.purchased);
      expect(mapped.transactionId, '1234567890123456789');
      expect(mapped.signedTransactionInfo, _signedTransaction);
      expect(mapped.appAccountToken, _accountToken);
      expect(mapped.pendingComplete, isTrue);
      expect(mapped.nativePurchase, same(native));
      expect(mapped.errorMessage, isNull);
    });

    test('restored StoreKit2 transactions retain server verification data', () {
      final mapped =
          mapAppleStorePurchase(_purchase(status: PurchaseStatus.restored));
      expect(mapped.status, AppleStorePurchaseStatus.restored);
      expect(mapped.signedTransactionInfo, _signedTransaction);
      // The plugin reports restored StoreKit2 transactions as already finished.
      expect(mapped.pendingComplete, isFalse);
    });

    test('missing account binding is passed to the server, never invented', () {
      expect(
          mapAppleStorePurchase(_purchase(appAccountToken: null))
              .appAccountToken,
          isNull);
    });

    test('pending and canceled events contain no verification or account data',
        () {
      for (final status in [PurchaseStatus.pending, PurchaseStatus.canceled]) {
        final mapped = mapAppleStorePurchase(_purchase(status: status));
        expect(mapped.signedTransactionInfo, isEmpty);
        expect(mapped.appAccountToken, isNull);
        expect(mapped.pendingComplete, isFalse);
        expect(mapped.errorMessage, isNull);
      }
    });

    test('platform error messages and details are never exposed', () {
      final native = _purchase(status: PurchaseStatus.error);
      native.error = IAPError(
        source: 'app_store',
        code: _rawSecret,
        message: _rawSecret,
        details: {'signedTransaction': _rawSecret},
      );
      final mapped = mapAppleStorePurchase(native);
      expect(mapped.status, AppleStorePurchaseStatus.error);
      expect(mapped.errorMessage, isNot(contains(_rawSecret)));
      expect(mapped.signedTransactionInfo, isEmpty);
      expect(mapped.appAccountToken, isNull);
    });

    test('refuses receipt-only and non-StoreKit2 successful transactions', () {
      for (final status in [
        PurchaseStatus.purchased,
        PurchaseStatus.restored
      ]) {
        final native = PurchaseDetails(
          productID: 'legacy',
          purchaseID: '123',
          verificationData: PurchaseVerificationData(
            localVerificationData: _rawSecret,
            serverVerificationData: _rawSecret,
            source: 'app_store',
          ),
          transactionDate: null,
          status: status,
        );
        final mapped = mapAppleStorePurchase(native);
        expect(mapped.status, AppleStorePurchaseStatus.error);
        expect(mapped.signedTransactionInfo, isEmpty);
        expect(mapped.errorMessage, isNot(contains(_rawSecret)));
      }
    });

    test('missing or malformed JWS and transaction identifiers fail closed',
        () {
      for (final native in [
        _purchase(signedTransaction: ''),
        _purchase(signedTransaction: 'receipt-data'),
        _purchase(signedTransaction: 'header..signature'),
        _purchase(transactionId: null),
        _purchase(transactionId: 'not-a-transaction'),
        _purchase(source: 'google_play'),
      ]) {
        final mapped = mapAppleStorePurchase(native);
        expect(mapped.status, AppleStorePurchaseStatus.error);
        expect(mapped.signedTransactionInfo, isEmpty);
        expect(mapped.appAccountToken, isNull);
      }
    });
  });

  group('native store adapter', () {
    late _FakeInAppPurchase native;
    late InAppApplePurchaseStore store;
    late int synchronizationCount;
    Object? synchronizationError;

    setUp(() {
      native = _FakeInAppPurchase();
      synchronizationCount = 0;
      synchronizationError = null;
      store = InAppApplePurchaseStore(
        inAppPurchase: native,
        synchronizePurchases: () async {
          synchronizationCount++;
          native.operations.add('sync');
          if (synchronizationError != null) throw synchronizationError!;
        },
      );
    });
    tearDown(() => native.updates.close());

    test('availability preserves false and strips native exceptions', () async {
      native.available = false;
      expect(await store.isAvailable(), isFalse);
      native.availabilityError = StateError(_rawSecret);
      await expectLater(store.isAvailable(), throwsA(_safeError));
    });

    test('initialization and product queries do not synchronize purchases',
        () async {
      expect(synchronizationCount, 0);
      await store.isAvailable();
      await store.queryProducts({'test'});
      final subscription = store.purchases.listen((_) {});
      await subscription.cancel();
      expect(synchronizationCount, 0);
      expect(native.operations, isEmpty);
    });

    test('queries only requested products and detects missing product IDs',
        () async {
      final product = _product();
      native.response = ProductDetailsResponse(
        productDetails: [product, _product(id: 'unrequested')],
        notFoundIDs: [],
      );
      final result = await store.queryProducts({product.id, 'missing'});
      expect(native.queriedIds, {product.id, 'missing'});
      expect(result.products.single.id, product.id);
      expect(result.notFoundIds, {'missing'});
      expect(() => result.products.clear(), throwsUnsupportedError);
      expect(() => result.notFoundIds.clear(), throwsUnsupportedError);
    });

    test('empty product query does not call the platform', () async {
      final result = await store.queryProducts({});
      expect(result.products, isEmpty);
      expect(result.notFoundIds, isEmpty);
      expect(native.queries, 0);
    });

    test('native query exception and response errors are safe', () async {
      native.queryError = StateError(_rawSecret);
      await expectLater(store.queryProducts({'test'}), throwsA(_safeError));
      native.queryError = null;
      native.response = ProductDetailsResponse(
        productDetails: [],
        notFoundIDs: [],
        error: IAPError(
          source: 'app_store',
          code: 'bad',
          message: _rawSecret,
        ),
      );
      await expectLater(store.queryProducts({'test'}), throwsA(_safeError));
    });

    test('purchases subscriptions using StoreKit2 and the server account UUID',
        () async {
      final product = _product();
      expect(await store.buy(mapAppleStoreProduct(product), _accountToken),
          isTrue);
      final param = native.lastPurchaseParam;
      expect(param, isA<Sk2PurchaseParam>());
      expect(param!.productDetails, same(product));
      expect(param.applicationUserName, _accountToken);
      expect((param as Sk2PurchaseParam).quantity, 1);
    });

    test('preserves purchase initiation false and strips errors', () async {
      native.buyResult = false;
      expect(await store.buy(mapAppleStoreProduct(_product()), _accountToken),
          isFalse);
      native.buyError = StateError(_rawSecret);
      await expectLater(
        store.buy(mapAppleStoreProduct(_product()), _accountToken),
        throwsA(_safeError),
      );
    });

    test('invalid account identifiers do not start a native purchase',
        () async {
      for (final token in ['test1', 'user@example.com', '']) {
        await expectLater(
          store.buy(mapAppleStoreProduct(_product()), token),
          throwsA(_safeError),
        );
      }
      expect(native.lastPurchaseParam, isNull);
    });

    test('unsupported and relabeled native subscription products are refused',
        () async {
      final mismatched = AppleStoreProduct(
        id: _product().id,
        title: 'Changed period',
        description: '',
        price: '₩9,900',
        currencyCode: 'KRW',
        subscriptionPeriod: 'year',
        nativeProduct: _product(),
      );
      for (final product in [
        mapAppleStoreProduct(_product(type: SK2ProductType.consumable)),
        mapAppleStoreProduct(_product(value: 2)),
        mismatched,
        const AppleStoreProduct(
          id: 'no-native',
          title: '',
          description: '',
          price: '',
          currencyCode: '',
          subscriptionPeriod: 'month',
        ),
      ]) {
        await expectLater(
            store.buy(product, _accountToken), throwsA(_safeError));
      }
      expect(native.lastPurchaseParam, isNull);
    });

    test('restoration passes account UUID but does not claim account filtering',
        () async {
      await store.restore(_accountToken);
      expect(synchronizationCount, 0);
      expect(native.operations, ['restore']);
      expect(native.lastRestoreAccount, _accountToken);
      native.restoreError = StateError(_rawSecret);
      await expectLater(store.restore(_accountToken), throwsA(_safeError));
    });

    test('ordinary restoration does not depend on forced synchronization',
        () async {
      synchronizationError = StateError(_rawSecret);
      await store.restore(_accountToken);
      expect(synchronizationCount, 0);
      expect(native.operations, ['restore']);
      expect(native.lastRestoreAccount, _accountToken);
      expect(native.completed, isEmpty);
    });

    test('explicit force synchronization runs once before native restoration',
        () async {
      await store.restore(_accountToken, synchronize: true);
      expect(synchronizationCount, 1);
      expect(native.operations, ['sync', 'restore']);
      expect(native.lastRestoreAccount, _accountToken);
    });

    test('invalid restoration account does not invoke native restoration',
        () async {
      await expectLater(store.restore('test1'), throwsA(_safeError));
      await expectLater(
          store.restore('test1', synchronize: true), throwsA(_safeError));
      expect(synchronizationCount, 0);
      expect(native.lastRestoreAccount, isNull);
    });

    test(
        'failed explicit synchronization is safe and does not restore stale data',
        () async {
      synchronizationError = StateError(_rawSecret);
      await expectLater(
          store.restore(_accountToken, synchronize: true), throwsA(_safeError));
      expect(synchronizationCount, 1);
      expect(native.operations, ['sync']);
      expect(native.lastRestoreAccount, isNull);
    });

    test('restoration waits for synchronization to finish', () async {
      final synchronization = Completer<void>();
      store = InAppApplePurchaseStore(
        inAppPurchase: native,
        synchronizePurchases: () => synchronization.future,
      );
      final restoration = store.restore(_accountToken, synchronize: true);
      await Future<void>.delayed(Duration.zero);
      expect(native.lastRestoreAccount, isNull);
      synchronization.complete();
      await restoration;
      expect(native.lastRestoreAccount, _accountToken);
    });

    for (final synchronizing in [true, false]) {
      final stage = synchronizing ? 'SYNC' : 'RESTORE';
      final knownCode = synchronizing
          ? 'storekit2_failed_to_sync_to_app_store'
          : 'storekit2_restore_failed';
      final otherStageCode = synchronizing
          ? 'storekit2_restore_failed'
          : 'storekit2_failed_to_sync_to_app_store';
      final knownDiagnostic = synchronizing ? 'STORE' : 'VERIFY';
      final errors = <(String, Object, String)>[
        (
          'known StoreKit code',
          PlatformException(
            code: knownCode,
            message: _rawSecret,
            details: {'receipt': _rawSecret, 'account': _rawSecret},
          ),
          knownDiagnostic,
        ),
        (
          'channel error',
          PlatformException(
            code: 'channel-error',
            message: _rawSecret,
            details: _rawSecret,
          ),
          'CHANNEL',
        ),
        (
          'unknown private code',
          PlatformException(
            code: _rawSecret,
            message: _rawSecret,
            details: [_rawSecret],
          ),
          'UNKNOWN',
        ),
        (
          'code for the other stage',
          PlatformException(
            code: otherStageCode,
            message: _rawSecret,
            details: _rawSecret,
          ),
          'UNKNOWN',
        ),
        ('missing plugin', MissingPluginException(_rawSecret), 'PLUGIN'),
        ('unexpected exception', StateError(_rawSecret), 'UNKNOWN'),
      ];
      for (final (description, exception, diagnostic) in errors) {
        test('$stage failure has only a fixed diagnostic: $description',
            () async {
          if (synchronizing) {
            synchronizationError = exception;
          } else {
            native.restoreError = exception;
          }
          await expectLater(
            store.restore(_accountToken, synchronize: synchronizing),
            throwsA(allOf(
              _safeError,
              isA<ApplePurchaseStoreException>().having(
                (error) => error.message,
                'stage diagnostic',
                endsWith('[IAP-$stage-$diagnostic]'),
              ),
            )),
          );
          expect(synchronizationCount, synchronizing ? 1 : 0);
          expect(native.operations, synchronizing ? ['sync'] : ['restore']);
          expect(native.lastRestoreAccount,
              synchronizing ? isNull : _accountToken);
          expect(native.completed, isEmpty);
        });
      }
    }

    test('force-sync success cannot hide a subsequent native restore failure',
        () async {
      native.restoreError = PlatformException(
        code: 'storekit2_restore_failed',
        message: _rawSecret,
        details: _rawSecret,
      );
      await expectLater(
        store.restore(_accountToken, synchronize: true),
        throwsA(allOf(
          _safeError,
          isA<ApplePurchaseStoreException>().having(
            (error) => error.message,
            'native restore diagnostic after force sync',
            endsWith('[IAP-RESTORE-VERIFY]'),
          ),
        )),
      );
      expect(synchronizationCount, 1);
      expect(native.operations, ['sync', 'restore']);
      expect(native.completed, isEmpty);
    });

    test('only unfinished transactions are completed', () async {
      final purchased = _purchase();
      await store.complete(mapAppleStorePurchase(purchased));
      expect(native.completed, [purchased]);
      await store.complete(
          mapAppleStorePurchase(_purchase(status: PurchaseStatus.restored)));
      await store.complete(
          mapAppleStorePurchase(_purchase(status: PurchaseStatus.pending)));
      expect(native.completed, [purchased]);
    });

    test('completion errors are sanitized', () async {
      native.completeError = StateError(_rawSecret);
      await expectLater(
        store.complete(mapAppleStorePurchase(_purchase())),
        throwsA(_safeError),
      );
    });

    test('streams mapped transactions without exposing native stream errors',
        () async {
      final first = store.purchases.first;
      native.updates.add([_purchase()]);
      final items = await first;
      expect(items.single.signedTransactionInfo, _signedTransaction);
      expect(() => items.clear(), throwsUnsupportedError);

      final error = expectLater(store.purchases.first, throwsA(_safeError));
      native.updates.addError(StateError(_rawSecret));
      await error;
    });
  });
}
