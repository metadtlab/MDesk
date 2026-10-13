/// A user-facing billing error. Never include tokens, receipts or raw server
/// responses in [message].
class AppleBillingException implements Exception {
  final String message;
  final bool retryable;
  final int? statusCode;

  const AppleBillingException(this.message,
      {this.retryable = false, this.statusCode});

  @override
  String toString() => message;
}

/// Billing is supported only by MDesk's first-party HTTPS account service.
/// Custom API servers must not receive App Store transaction proofs.
String normalizedAppleBillingOrigin(String value) {
  final uri = Uri.tryParse(value);
  final canonicalOrigin = RegExp(
    r'^https://admin\.787\.kr(?::443)?/?$',
    caseSensitive: false,
  ).hasMatch(value);
  if (!canonicalOrigin ||
      uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.toLowerCase() != 'admin.787.kr' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const AppleBillingException('인앱결제는 MDesk 공식 계정 서버에서만 사용할 수 있습니다.');
  }
  return 'https://admin.787.kr';
}

bool isAppleBillingAccountToken(String value) => RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
    ).hasMatch(value);

class BillingSession {
  final String origin;
  final String userId;
  final int generation;
  final String accessToken;

  const BillingSession({
    required this.origin,
    required this.userId,
    required this.generation,
    required this.accessToken,
  });

  String get normalizedOrigin => normalizedAppleBillingOrigin(origin);

  /// Access-token rotation does not change the purchasing account identity.
  bool sameIdentityAs(BillingSession other) {
    try {
      return normalizedOrigin == other.normalizedOrigin &&
          userId == other.userId &&
          generation == other.generation;
    } on AppleBillingException {
      return false;
    }
  }
}

class AppleBillingProductConfig {
  final String id;

  /// Only monthly and yearly auto-renewable subscriptions are supported.
  final String period;

  const AppleBillingProductConfig({required this.id, required this.period});

  factory AppleBillingProductConfig.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final period = json['period'];
    if (id is! String ||
        id.trim().isEmpty ||
        id != id.trim() ||
        (period != 'month' && period != 'year')) {
      throw const AppleBillingException('인앱결제 상품 설정을 확인할 수 없습니다.');
    }
    return AppleBillingProductConfig(id: id, period: period as String);
  }
}

class AppleBillingConfig {
  final bool enabled;
  final String? appAccountToken;
  final List<AppleBillingProductConfig> products;

  const AppleBillingConfig({
    required this.enabled,
    this.appAccountToken,
    this.products = const [],
  });

  factory AppleBillingConfig.fromJson(Map<String, dynamic> json) {
    final enabled = json['enabled'];
    if (enabled == false) {
      return const AppleBillingConfig(enabled: false);
    }
    final token = json['app_account_token'];
    final productList = json['products'];
    if (enabled != true ||
        token is! String ||
        !isAppleBillingAccountToken(token) ||
        productList is! List ||
        productList.isEmpty) {
      throw const AppleBillingException('인앱결제가 아직 준비되지 않았습니다.');
    }
    final products = <AppleBillingProductConfig>[];
    final ids = <String>{};
    for (final item in productList) {
      if (item is! Map<String, dynamic>) {
        throw const AppleBillingException('인앱결제 상품 설정을 확인할 수 없습니다.');
      }
      final product = AppleBillingProductConfig.fromJson(item);
      if (!ids.add(product.id)) {
        throw const AppleBillingException('인앱결제 상품 설정을 확인할 수 없습니다.');
      }
      products.add(product);
    }
    return AppleBillingConfig(
      enabled: true,
      appAccountToken: token,
      products: List.unmodifiable(products),
    );
  }
}

class AppleBillingTransaction {
  final String transactionId;
  final String productId;
  final String signedTransactionInfo;
  final String? appAccountToken;

  const AppleBillingTransaction({
    required this.transactionId,
    required this.productId,
    required this.signedTransactionInfo,
    this.appAccountToken,
  });
}
