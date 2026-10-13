import 'dart:async';

import 'package:flutter/material.dart';

import '../common.dart';
import '../common/widgets/login.dart';
import '../mobile/pages/apple_subscription_page.dart';
import '../models/apple_billing_model.dart';
import '../models/apple_billing_types.dart';
import '../models/platform_model.dart';
import '../models/user_model.dart';
import 'apple_billing_backend.dart';
import 'apple_billing_session.dart';
import 'apple_purchase_store.dart';

_AppleBillingService? _service;

/// iOS only: no store object, listener, or billing request on other platforms.
void startAppleBilling() {
  if (!isIOS || bind.isDisableAccount()) return;
  _service ??= _AppleBillingService();
}

void openAppleSubscriptionPage(BuildContext context) {
  startAppleBilling();
  final service = _service;
  if (service == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppleSubscriptionPage(
      model: service.model,
      accountName: () => gFFI.userModel.userName.value,
      onLogin: () => loginDialog(),
    ),
  ));
}

/// One listener for the entire app lifetime, including off-screen purchases.
class _AppleBillingService with WidgetsBindingObserver {
  _AppleBillingService() {
    final backend = SessionRefreshingAppleBillingBackend(
      backend: HttpAppleBillingBackend(),
      currentSession: _currentSession,
      recoverSession: _recoverSession,
    );
    model = AppleBillingModel(
      store: InAppApplePurchaseStore(),
      backend: backend,
      currentSession: _currentSession,
      refreshAccount: _refreshAccount,
    );
    // Bind before loading account information or displaying a purchase screen.
    gFFI.userModel.userName.listen((_) => _scheduleAccountChange());
    gFFI.userModel.userPkid.listen((_) => _scheduleAccountChange());
    WidgetsBinding.instance.addObserver(this);
    model.start();
  }

  late final AppleBillingModel model;
  bool _accountChangeScheduled = false;

  void _scheduleAccountChange() {
    if (_accountChangeScheduled) return;
    _accountChangeScheduled = true;
    scheduleMicrotask(() {
      _accountChangeScheduled = false;
      model.accountChanged();
    });
  }

  Future<BillingSession?> _currentSession({bool refreshToken = true}) async {
    final user = gFFI.userModel;
    if (!user.isLogin ||
        user.isBiometricLocked ||
        user.isSessionTransitioning ||
        bind.isDisableAccount()) {
      return null;
    }
    final generation = user.sessionGeneration;
    final id = user.userPkid.value;
    final name = user.userName.value;
    bool stillCurrent() =>
        user.isLogin &&
        !user.isBiometricLocked &&
        user.sessionGeneration == generation &&
        user.userPkid.value == id &&
        user.userName.value == name;

    // Validate the account's own server before reading/sending its credentials.
    final origin = normalizedAppleBillingOrigin(await user.accountApiServer());
    if (!stillCurrent()) return null;
    if (id.isEmpty) {
      throw const AppleBillingException('MDesk 계정 정보를 확인 중입니다. 잠시 후 새로고침하세요.');
    }
    if (refreshToken) {
      final result = await user.refreshAccessToken(
        force: bind.mainGetLocalOption(key: 'access_token').isEmpty,
        expectedOrigin: origin,
        expectedGeneration: generation,
      );
      if (!stillCurrent()) return null;
      if (result == TokenRefreshResult.rejected) {
        await user.reset(resetOther: true);
        return null;
      }
      if (result == TokenRefreshResult.unavailable) {
        throw const AppleBillingException('로그인 상태를 확인하지 못했습니다. 잠시 후 다시 시도하세요.',
            retryable: true);
      }
    }
    final token = bind.mainGetLocalOption(key: 'access_token');
    final currentOrigin =
        normalizedAppleBillingOrigin(await user.accountApiServer());
    if (!stillCurrent() || currentOrigin != origin) return null;
    if (token.isEmpty) {
      throw const AppleBillingException('로그인이 만료되었습니다. 다시 로그인해 주세요.');
    }
    return BillingSession(
      origin: origin,
      userId: id,
      generation: generation,
      accessToken: token,
    );
  }

  Future<bool> _recoverSession(BillingSession original) async {
    final before = await _currentSession(refreshToken: false);
    if (before == null || !original.sameIdentityAs(before)) return false;
    final user = gFFI.userModel;
    final result = await user.refreshAccessToken(
      force: true,
      expectedOrigin: original.normalizedOrigin,
      expectedGeneration: original.generation,
    );
    final after = await _currentSession(refreshToken: false);
    if (after == null || !original.sameIdentityAs(after)) return false;
    if (result == TokenRefreshResult.rejected ||
        result == TokenRefreshResult.notConfigured) {
      await user.reset(resetOther: true);
      return false;
    }
    return result == TokenRefreshResult.success;
  }

  Future<void> _refreshAccount() async {
    final session = await _currentSession();
    if (session == null) {
      throw const AppleBillingException('구매한 MDesk 계정으로 다시 로그인해 주세요.');
    }
    // UserModel skips overlapping refreshes. Wait briefly so the revision below
    // actually proves receipt of new server-authoritative account information.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (refreshingUser) {
      if (DateTime.now().isAfter(deadline)) {
        throw const AppleBillingException(
            '계정 권한을 확인 중입니다. 잠시 후 구매 확인을 재시도하세요.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final before = await _currentSession();
    if (before == null || !session.sameIdentityAs(before)) {
      throw const AppleBillingException('로그인 계정이 변경되었습니다.');
    }
    final user = gFFI.userModel;
    final revision = user.serverInfoRevision;
    await user.refreshCurrentUser().timeout(const Duration(seconds: 20));
    final after = await _currentSession();
    if (after == null ||
        !session.sameIdentityAs(after) ||
        user.serverInfoRevision == revision ||
        user.networkError.value.isNotEmpty) {
      throw const AppleBillingException('서버의 계정 권한을 확인하지 못했습니다. 구매 확인을 재시도하세요.',
          retryable: true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Never invoke AppStore.sync automatically; explicit restoration owns it.
    unawaited(model.reload());
    if (gFFI.userModel.isLogin) {
      unawaited(gFFI.userModel.refreshCurrentUser());
    }
  }
}
