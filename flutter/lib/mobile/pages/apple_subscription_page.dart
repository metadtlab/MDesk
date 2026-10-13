import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/apple_billing_model.dart';
import '../../utils/apple_purchase_store.dart';

/// Presentation only: the supplied model owns StoreKit and account verification.
/// This page neither grants account access nor owns/disposes the shared model.
class AppleSubscriptionPage extends StatefulWidget {
  const AppleSubscriptionPage({
    super.key,
    required this.model,
    required this.onLogin,
    this.accountName,
  });

  final AppleBillingModel model;
  final VoidCallback onLogin;
  final String Function()? accountName;

  @override
  State<AppleSubscriptionPage> createState() => _AppleSubscriptionPageState();
}

class _AppleSubscriptionPageState extends State<AppleSubscriptionPage> {
  static final _manageUri =
      Uri.parse('https://apps.apple.com/account/subscriptions');
  static final _privacyUri =
      Uri.parse('https://www.mdesk.co.kr/privacy-policy.html');
  static final _termsUri = Uri.parse(
      'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/');

  @override
  void initState() {
    super.initState();
    _reloadAfterFrame();
  }

  @override
  void didUpdateWidget(covariant AppleSubscriptionPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) _reloadAfterFrame();
  }

  void _reloadAfterFrame() {
    final model = widget.model;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(model, widget.model)) _perform(model.reload);
    });
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Never display raw exceptions, account tokens or transaction proofs.
      _showError('요청을 처리하지 못했습니다. 잠시 후 다시 시도하세요.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openLink(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) _showError('링크를 열지 못했습니다. 잠시 후 다시 시도하세요.');
    } catch (_) {
      _showError('링크를 열지 못했습니다. 잠시 후 다시 시도하세요.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App Store 구독')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: AnimatedBuilder(
              animation: widget.model,
              builder: (context, _) {
                final model = widget.model;
                final name = model.loggedIn
                    ? widget.accountName?.call().trim() ?? ''
                    : '';
                return ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    Text(
                      model.loggedIn
                          ? (name.isEmpty ? '로그인한 MDesk 계정' : 'MDesk 계정: $name')
                          : 'MDesk 계정 로그인이 필요합니다',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '구매한 MDesk 계정에 구독이 연결됩니다. 구매 복원 시에도 같은 계정으로 로그인하세요.',
                    ),
                    if (!model.loggedIn) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ElevatedButton(
                          key: const ValueKey('apple-subscription-login'),
                          onPressed: widget.onLogin,
                          child: const Text('MDesk 로그인'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    const Text(
                      '기존 유료회원은 이용 권한을 먼저 확인하세요. 이미 필요한 이용 권한이 있다면 중복 구독하지 마세요.',
                    ),
                    if (model.busy) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                      const SizedBox(height: 8),
                      Text(model.loading
                          ? '구독 정보를 불러오는 중입니다.'
                          : model.verifying
                              ? '구매 내역을 서버에서 확인하는 중입니다.'
                              : model.restoring
                                  ? '구매 복원을 요청하는 중입니다.'
                                  : 'App Store 구매 확인을 기다리는 중입니다.'),
                    ],
                    if (model.error != null && model.error!.isNotEmpty)
                      _Notice(text: model.error!, isError: true),
                    if (model.message != null && model.message!.isNotEmpty)
                      _Notice(text: model.message!),
                    if (model.loggedIn && !model.loading && !model.configured)
                      const _Notice(
                        text: '현재 App Store 구매와 복원을 시작할 수 없습니다. '
                            '구독 관리에서는 기존 Apple 구독을 확인하거나 해지할 수 있습니다.',
                      ),
                    for (final product in model.products)
                      _productCard(context, product),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: const ValueKey('apple-subscription-restore'),
                          onPressed: model.canRestore
                              ? () => _perform(model.restore)
                              : null,
                          child: const Text('구매 복원'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('apple-subscription-sync'),
                          onPressed: model.canRestore
                              ? () => _perform(
                                  () => model.restore(synchronize: true))
                              : null,
                          child: const Text('구매 누락 시 App Store 동기화'),
                        ),
                        OutlinedButton(
                          key: const ValueKey('apple-subscription-reload'),
                          onPressed:
                              model.busy ? null : () => _perform(model.reload),
                          child: const Text('구독 정보 새로고침'),
                        ),
                        if (model.hasUnverifiedPurchases)
                          OutlinedButton(
                            key: const ValueKey('apple-subscription-retry'),
                            onPressed: model.busy
                                ? null
                                : () => _perform(model.retryVerification),
                            child: const Text('구매 확인 재시도'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '이미 구매했는데 내역이 보이지 않는 경우에만 App Store 동기화를 사용하세요. Apple 계정 인증이 필요할 수 있습니다.',
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      '월간 상품은 1개월, 연간 상품은 1년마다 자동 갱신됩니다. '
                      '결제는 구매를 확인한 Apple 계정으로 청구됩니다. '
                      '다음 갱신을 원하지 않으면 구독 기간이 끝나기 전에 Apple 구독 관리에서 해지하세요. '
                      '정확한 청구 및 갱신 조건은 App Store 구매 확인 화면에서 확인하세요.',
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton(
                          key: const ValueKey('apple-subscription-manage'),
                          onPressed: () => _openLink(_manageUri),
                          child: const Text('Apple 구독 관리·해지'),
                        ),
                        TextButton(
                          key: const ValueKey('apple-subscription-privacy'),
                          onPressed: () => _openLink(_privacyUri),
                          child: const Text('개인정보처리방침'),
                        ),
                        TextButton(
                          key: const ValueKey('apple-subscription-terms'),
                          onPressed: () => _openLink(_termsUri),
                          child: const Text('이용약관 (Apple 표준 EULA)'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _productCard(BuildContext context, AppleStoreProduct product) {
    final model = widget.model;
    final period = model.periodFor(product.id);
    final periodLabel = switch (period) {
      'month' => '1개월',
      'year' => '1년',
      _ => null,
    };
    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(product.title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(product.description),
            const SizedBox(height: 12),
            Text(
                periodLabel == null
                    ? product.price
                    : '${product.price} / $periodLabel',
                style: Theme.of(context).textTheme.titleMedium),
            Text(periodLabel == null
                ? '구독 기간을 확인할 수 없습니다. 구독 정보를 새로고침하세요.'
                : '갱신 주기: $periodLabel (자동 갱신)'),
            const SizedBox(height: 12),
            ElevatedButton(
              key: ValueKey('apple-subscription-buy-${product.id}'),
              onPressed: periodLabel != null && model.canBuy(product)
                  ? () => _perform(() => model.buy(product))
                  : null,
              child: const Text('App Store에서 구독하기'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Text(
          text,
          style: TextStyle(
            color: isError ? Theme.of(context).colorScheme.error : null,
          ),
        ),
      ),
    );
  }
}
