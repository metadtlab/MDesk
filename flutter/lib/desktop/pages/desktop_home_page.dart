import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/animated_rotation_widget.dart';
import 'package:flutter_hbb/common/widgets/custom_password.dart';
import 'package:flutter_hbb/common/widgets/login.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/connection_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/desktop/widgets/update_progress.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/server_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/plugin/ui_manager.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:window_size/window_size.dart' as window_size;

class DesktopHomePage extends StatefulWidget {
  const DesktopHomePage({Key? key}) : super(key: key);

  @override
  State<DesktopHomePage> createState() => _DesktopHomePageState();
}

const borderColor = Color(0xFF2F65BA);

class _DesktopHomePageState extends State<DesktopHomePage>
    with AutomaticKeepAliveClientMixin {
  final _leftPaneScrollController = ScrollController();

  @override
  bool get wantKeepAlive => true;
  var systemError = '';
  StreamSubscription? _uniLinksSubscription;
  var svcStopped = false.obs;
  var watchIsCanScreenRecording = false;
  var watchIsProcessTrust = false;
  var watchIsInputMonitoring = false;
  var watchIsCanRecordAudio = false;
  Timer? _updateTimer;
  bool isCardClosed = false;

  final RxBool _editHover = false.obs;

  final GlobalKey _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final isIncomingOnly = bind.isIncomingOnly();
    // 원격 진행 중에도 메인 MDesk UI 조작 가능하도록 차단 오버레이 비사용
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        buildLeftPane(context),
        if (!isIncomingOnly) const VerticalDivider(width: 1),
        if (!isIncomingOnly) Expanded(child: buildRightPane(context)),
      ],
    );
  }

  Widget buildLeftPane(BuildContext context) {
    final isIncomingOnly = bind.isIncomingOnly();
    final isOutgoingOnly = bind.isOutgoingOnly();
    final children = <Widget>[
      if (!isOutgoingOnly) buildPresetPasswordWarning(),
      if (bind.isCustomClient())
        Align(
          alignment: Alignment.center,
          child: loadPowered(context),
        ),
      Align(
        alignment: Alignment.center,
        child: loadLogo(),
      ),
      _buildVersionLabel(context),
      buildTip(context),
      if (!isOutgoingOnly) buildIDBoard(context),
      if (!isOutgoingOnly) buildPasswordBoard(context),
      if (!isOutgoingOnly) buildLinkSection(context),
      if (!bind.isDisableAccount()) buildLoginSection(context),
      FutureBuilder<Widget>(
        future: Future.value(
            Obx(() => buildHelpCards(stateGlobal.updateUrl.value))),
        builder: (_, data) {
          if (data.hasData) {
            if (isIncomingOnly) {
              if (isInHomePage()) {
                Future.delayed(Duration(milliseconds: 300), () {
                  _updateWindowSize();
                });
              }
            }
            return data.data!;
          } else {
            return const Offstage();
          }
        },
      ),
      buildPluginEntry(),
    ];
    if (isIncomingOnly) {
      children.addAll([
        Divider(),
        OnlineStatusWidget(
          onSvcStatusChanged: () {
            if (isInHomePage()) {
              Future.delayed(Duration(milliseconds: 300), () {
                _updateWindowSize();
              });
            }
          },
        ).marginOnly(bottom: 6, right: 6)
      ]);
    }
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return ChangeNotifierProvider.value(
      value: gFFI.serverModel,
      child: Container(
        width: isIncomingOnly ? 280.0 : 200.0,
        color: Colors.transparent,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    controller: _leftPaneScrollController,
                    child: Column(
                      key: _childKey,
                      children: children,
                    ),
                  ),
                ),
              ],
            ),
            if (isOutgoingOnly)
              Positioned(
                bottom: 6,
                left: 12,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InkWell(
                    child: Obx(
                      () => Icon(
                        Icons.settings,
                        color: _editHover.value
                            ? textColor
                            : Colors.grey.withOpacity(0.5),
                        size: 22,
                      ),
                    ),
                    onTap: () => {
                      if (DesktopSettingPage.tabKeys.isNotEmpty)
                        {
                          DesktopSettingPage.switch2page(
                              DesktopSettingPage.tabKeys[0])
                        }
                    },
                    onHover: (value) => _editHover.value = value,
                  ),
                ),
              )
          ],
        ),
      ),
    );
  }

  buildRightPane(BuildContext context) {
    return Container(
      color: Colors.transparent,
      child: ConnectionPage(),
    );
  }

  buildIDBoard(BuildContext context) {
    final model = gFFI.serverModel;
    return Container(
      margin: const EdgeInsets.only(left: 20, right: 11),
      height: 57,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Container(
            width: 2,
            decoration: const BoxDecoration(color: MyTheme.accent),
          ).marginOnly(top: 5),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    height: 25,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          translate("ID"),
                          style: TextStyle(
                              fontSize: 14,
                              color: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.color
                                  ?.withOpacity(0.5)),
                        ).marginOnly(top: 5),
                        buildPopupMenu(context)
                      ],
                    ),
                  ),
                  Flexible(
                    child: GestureDetector(
                      onDoubleTap: () {
                        Clipboard.setData(
                            ClipboardData(text: model.serverId.text));
                        showToast(translate("Copied"));
                      },
                      child: TextFormField(
                        controller: model.serverId,
                        readOnly: true,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          filled: true,
                          fillColor: Colors.transparent,
                          hoverColor: Colors.transparent,
                          contentPadding: EdgeInsets.only(top: 10, bottom: 10),
                        ),
                        style: TextStyle(
                          fontSize: 22,
                        ),
                      ).workaroundFreezeLinuxMint(),
                    ),
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget buildPopupMenu(BuildContext context) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    RxBool hover = false.obs;
    return InkWell(
      onTap: DesktopTabPage.onAddSetting,
      child: Tooltip(
        message: translate('Settings'),
        child: Obx(
          () => CircleAvatar(
            radius: 15,
            backgroundColor: hover.value
                ? Theme.of(context).scaffoldBackgroundColor
                : Theme.of(context).colorScheme.background,
            child: Icon(
              Icons.settings_outlined,
              size: 20,
              color: hover.value ? textColor : textColor?.withOpacity(0.5),
            ),
          ),
        ),
      ),
      onHover: (value) => hover.value = value,
    );
  }

  buildPasswordBoard(BuildContext context) {
    return ChangeNotifierProvider.value(
        value: gFFI.serverModel,
        child: Consumer<ServerModel>(
          builder: (context, model, child) {
            return buildPasswordBoard2(context, model);
          },
        ));
  }

  buildPasswordBoard2(BuildContext context, ServerModel model) {
    RxBool refreshHover = false.obs;
    RxBool editHover = false.obs;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final iconIdle = Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : Colors.black;
    final showOneTime = model.approveMode != 'click' &&
        model.verificationMethod != kUsePermanentPassword;
    return Container(
      margin: EdgeInsets.only(left: 20.0, right: 16, top: 13, bottom: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Container(
            width: 2,
            height: 52,
            decoration: BoxDecoration(color: MyTheme.accent),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AutoSizeText(
                    translate("One-time Password"),
                    style: TextStyle(
                        fontSize: 14, color: textColor?.withOpacity(0.5)),
                    maxLines: 1,
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onDoubleTap: () {
                            if (showOneTime) {
                              Clipboard.setData(
                                  ClipboardData(text: model.serverPasswd.text));
                              showToast(translate("Copied"));
                            }
                          },
                          child: TextFormField(
                            controller: model.serverPasswd,
                            readOnly: true,
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              filled: true,
                              fillColor: Colors.transparent,
                              hoverColor: Colors.transparent,
                              contentPadding:
                                  EdgeInsets.only(top: 14, bottom: 10),
                            ),
                            style: TextStyle(fontSize: 15),
                          ).workaroundFreezeLinuxMint(),
                        ),
                      ),
                      if (showOneTime)
                        AnimatedRotationWidget(
                          onPressed: () => bind.mainUpdateTemporaryPassword(),
                          child: Tooltip(
                            message: translate('Refresh Password'),
                            child: Obx(() => RotatedBox(
                                quarterTurns: 2,
                                child: Icon(
                                  Icons.refresh,
                                  color:
                                      refreshHover.value ? textColor : iconIdle,
                                  size: 22,
                                ))),
                          ),
                          onHover: (value) => refreshHover.value = value,
                        ).marginOnly(right: 8, top: 4),
                      if (!bind.isDisableSettings())
                        InkWell(
                          child: Tooltip(
                            message: translate('Change Password'),
                            child: Obx(
                              () => Icon(
                                Icons.edit,
                                color: editHover.value ? textColor : iconIdle,
                                size: 22,
                              ).marginOnly(right: 8, top: 4),
                            ),
                          ),
                          onTap: () => DesktopSettingPage.switch2page(
                              SettingsTabKey.safety),
                          onHover: (value) => editHover.value = value,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVersionLabel(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(left: 20, right: 16, top: 4, bottom: 0),
      child: _VersionLabelWithRefresh(),
    );
  }

  buildTip(BuildContext context) {
    final isOutgoingOnly = bind.isOutgoingOnly();
    return Padding(
      padding:
          const EdgeInsets.only(left: 20.0, right: 16, top: 16.0, bottom: 5),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              if (!isOutgoingOnly)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    translate("Your Desktop"),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
            ],
          ),
          SizedBox(
            height: 10.0,
          ),
          if (!isOutgoingOnly)
            Text(
              translate("desk_tip"),
              overflow: TextOverflow.clip,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (isOutgoingOnly)
            Text(
              translate("outgoing_only_desk_tip"),
              overflow: TextOverflow.clip,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }

  /// 파일명에서 userId 파싱
  String _parseUserId() {
    String filename = Platform.environment['MDESK_APPNAME'] ??
        Platform.environment['RUSTDESK_APPNAME'] ??
        '';

    if (filename.isEmpty) {
      filename = Platform.resolvedExecutable.split(Platform.pathSeparator).last;
    }

    // id= 파싱
    final idMatch = RegExp(r'id=([^,\s]+)').firstMatch(filename);
    return idMatch?.group(1) ?? '';
  }

  Widget buildLinkSection(BuildContext context) {
    // 1순위: 로그인한 사용자 이름, 2순위: 파일명에서 파싱
    final loggedInUser = gFFI.userModel.userName.value;
    final fileUserId = _parseUserId();
    final userId = loggedInUser.isNotEmpty ? loggedInUser : fileUserId;
    final textColor = Theme.of(context).textTheme.titleLarge?.color;

    return Padding(
      padding:
          const EdgeInsets.only(left: 20.0, right: 16, top: 10, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Obx(() {
            final isLoggedIn = gFFI.userModel.userName.value.isNotEmpty;
            final userName = gFFI.userModel.userName.value;

            // 로그인된 경우: username 기준 접속 URL
            if (isLoggedIn) {
              final usernameUrl = 'https://787.kr/$userName';

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // username 링크 (표시: 베이스 URL, 이동/복사: 전체 URL)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      InkWell(
                        onTap: () async {
                          await launchUrl(Uri.parse(usernameUrl));
                        },
                        child: Text(
                          'https://787.kr',
                          style: TextStyle(
                            color: MyTheme.accent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                            decorationColor: MyTheme.accent,
                            shadows: [
                              Shadow(
                                color: Colors.white.withOpacity(0.85),
                                blurRadius: 2,
                              ),
                              const Shadow(
                                color: Color(0x55000000),
                                blurRadius: 3,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: usernameUrl));
                          showToast(translate("Copied"));
                        },
                        child: Icon(
                          Icons.content_copy,
                          size: 16,
                          color: textColor?.withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            }

            // 로그인 안된 경우: 파일명에서 파싱한 userId 사용
            final url = fileUserId.isNotEmpty
                ? 'https://787.kr/$fileUserId'
                : 'https://787.kr';
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                InkWell(
                  onTap: () async {
                    await launchUrl(Uri.parse(url));
                  },
                  child: Text(
                    'https://787.kr',
                    style: TextStyle(
                      color: MyTheme.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                      decorationColor: MyTheme.accent,
                      shadows: [
                        Shadow(
                          color: Colors.white.withOpacity(0.85),
                          blurRadius: 2,
                        ),
                        const Shadow(
                          color: Color(0x55000000),
                          blurRadius: 3,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                InkWell(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: url));
                    showToast(translate("Copied"));
                  },
                  child: Icon(
                    Icons.content_copy,
                    size: 16,
                    color: textColor?.withOpacity(0.5),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  /// Tinted “glass” button — blur 제거(밝은 배경에서 글자 안 보이는 문제 방지)
  Widget _glassPrimaryButton({
    required VoidCallback onPressed,
    required Widget child,
    required List<Color> gradientColors,
  }) {
    const radius = 14.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Material(
        type: MaterialType.transparency,
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(radius),
          splashColor: Colors.white.withOpacity(0.28),
          highlightColor: Colors.white.withOpacity(0.12),
          hoverColor: Colors.white.withOpacity(0.16),
          focusColor: Colors.white.withOpacity(0.10),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color: Colors.white.withOpacity(0.55),
                width: 1.2,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradientColors,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// Outline glass (secondary) — blur 제거
  Widget _glassSecondaryButton({
    required VoidCallback onPressed,
    required Widget child,
    required Color accent,
  }) {
    const radius = 14.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Material(
        type: MaterialType.transparency,
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(radius),
          splashColor: accent.withOpacity(0.18),
          highlightColor: Colors.white.withOpacity(0.08),
          hoverColor: accent.withOpacity(0.14),
          focusColor: accent.withOpacity(0.08),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(
                color:
                    Color.lerp(Colors.white, accent, 0.35)!.withOpacity(0.85),
                width: 1.2,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withOpacity(0.72),
                  Colors.white.withOpacity(0.42),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }

  /// 설치/업데이트 알림 카드용 버튼 — 블러 없이 진한 틴트로 대비 확보
  Widget _glassInstallCardActionButton({
    required String labelKey,
    required GestureTapCallback onTap,
    double width = 150,
  }) {
    return SizedBox(
      width: width,
      child: Material(
        type: MaterialType.transparency,
        color: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.zero,
          splashColor: Colors.white.withOpacity(0.22),
          highlightColor: Colors.white.withOpacity(0.10),
          hoverColor: Colors.white.withOpacity(0.18),
          focusColor: Colors.white.withOpacity(0.10),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.zero,
              border: Border.all(
                color: Colors.white.withOpacity(0.85),
                width: 1.2,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0xCC1A5F8A),
                  const Color(0xCC0D4A6E),
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: AutoSizeText(
                      translate(labelKey),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 20,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        shadows: [
                          Shadow(
                            color: Color(0x80000000),
                            blurRadius: 3,
                            offset: Offset(0, 1),
                          ),
                        ],
                      ),
                    ).marginSymmetric(horizontal: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget buildLoginSection(BuildContext context) {
    final accent = MyTheme.accent;
    return Padding(
      padding: const EdgeInsets.only(left: 20.0, right: 16, top: 5, bottom: 10),
      child: Column(
        children: [
          Obx(() {
            final isLoggedIn = gFFI.userModel.userName.value.isNotEmpty;
            final List<Color> gradientColors = isLoggedIn
                ? [
                    Colors.red.shade400.withOpacity(0.78),
                    Colors.red.shade700.withOpacity(0.58),
                  ]
                : [
                    accent.withOpacity(0.90),
                    accent.withOpacity(0.72),
                  ];
            return SizedBox(
              width: double.infinity,
              child: _glassPrimaryButton(
                gradientColors: gradientColors,
                onPressed: () {
                  if (isLoggedIn) {
                    logOutConfirmDialog();
                  } else {
                    loginDialog();
                  }
                },
                child: Text(
                  isLoggedIn
                      ? '${translate('Logout')} (${gFFI.userModel.userName.value})'
                      : translate('Login'),
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    shadows: [
                      Shadow(
                        color: Color(0x40000000),
                        blurRadius: 2,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          Obx(() {
            final isLoggedIn = gFFI.userModel.userName.value.isNotEmpty;
            if (isLoggedIn) return const SizedBox.shrink();
            return Column(
              children: [
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: _glassSecondaryButton(
                    accent: accent,
                    onPressed: () async {
                      await launchUrl(Uri.parse(
                          'https://admin.787.kr/api/user_action?action=register'));
                    },
                    child: Text(
                      translate('회원가입'),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: accent,
                        shadows: [
                          Shadow(
                            color: Colors.white.withOpacity(0.5),
                            blurRadius: 0,
                            offset: Offset(0, 0.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget buildHelpCards(String updateUrl) {
    // MDesk 업데이트 체크 - 새 버전이 있으면 표시
    if (updateUrl.isNotEmpty && !isCardClosed) {
      final latestVersion = stateGlobal.latestVersion.value;
      final appName = bind.mainGetAppNameSync();

      return FutureBuilder<String>(
        future: bind.mainGetVersion(),
        builder: (context, snapshot) {
          final currentVersion = snapshot.hasData ? snapshot.data! : '...';
          return buildInstallCard(
              "새 버전 알림",
              "$appName $latestVersion 버전이 출시되었습니다.\n현재 버전: $currentVersion",
              "다운로드", () async {
            if (isWindows) {
              handleDirectDownloadUpdate(updateUrl);
            } else {
              await launchUrl(Uri.parse(updateUrl));
            }
          }, closeButton: true);
        },
      );
    }
    if (systemError.isNotEmpty) {
      return buildInstallCard("", systemError, "", () {});
    }

    if (isWindows && !bind.isDisableInstallation()) {
      if (!bind.mainIsInstalled()) {
        return buildInstallCard(
            "", bind.isOutgoingOnly() ? "" : "install_tip", "Install",
            () async {
          await rustDeskWinManager.closeAllSubWindows();
          bind.mainGotoInstall();
        });
      } else if (bind.mainIsInstalledLowerVersion()) {
        return buildInstallCard(
            "Status", "Your installation is lower version.", "Click to upgrade",
            () async {
          await rustDeskWinManager.closeAllSubWindows();
          bind.mainUpdateMe();
        });
      }
    } else if (isMacOS) {
      final isOutgoingOnly = bind.isOutgoingOnly();
      if (!(isOutgoingOnly || bind.mainIsCanScreenRecording(prompt: false))) {
        return buildInstallCard("Permissions", "config_screen", "Configure",
            () async {
          bind.mainIsCanScreenRecording(prompt: true);
          watchIsCanScreenRecording = true;
        }, help: 'Help', link: translate("doc_mac_permission"));
      } else if (!isOutgoingOnly && !bind.mainIsProcessTrusted(prompt: false)) {
        return buildInstallCard("Permissions", "config_acc", "Configure",
            () async {
          bind.mainIsProcessTrusted(prompt: true);
          watchIsProcessTrust = true;
        }, help: 'Help', link: translate("doc_mac_permission"));
      } else if (!bind.mainIsCanInputMonitoring(prompt: false)) {
        return buildInstallCard("Permissions", "config_input", "Configure",
            () async {
          bind.mainIsCanInputMonitoring(prompt: true);
          watchIsInputMonitoring = true;
        }, help: 'Help', link: translate("doc_mac_permission"));
      } else if (!isOutgoingOnly &&
          !svcStopped.value &&
          bind.mainIsInstalled() &&
          !bind.mainIsInstalledDaemon(prompt: false)) {
        return buildInstallCard("", "install_daemon_tip", "Install", () async {
          bind.mainIsInstalledDaemon(prompt: true);
        });
      }
      //// Disable microphone configuration for macOS. We will request the permission when needed.
      // else if ((await osxCanRecordAudio() !=
      //     PermissionAuthorizeType.authorized)) {
      //   return buildInstallCard("Permissions", "config_microphone", "Configure",
      //       () async {
      //     osxRequestAudio();
      //     watchIsCanRecordAudio = true;
      //   });
      // }
    } else if (isLinux) {
      if (bind.isOutgoingOnly()) {
        return Container();
      }
      final LinuxCards = <Widget>[];
      if (bind.isSelinuxEnforcing()) {
        // Check is SELinux enforcing, but show user a tip of is SELinux enabled for simple.
        final keyShowSelinuxHelpTip = "show-selinux-help-tip";
        if (bind.mainGetLocalOption(key: keyShowSelinuxHelpTip) != 'N') {
          LinuxCards.add(buildInstallCard(
            "Warning",
            "selinux_tip",
            "",
            () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link:
                'https://rustdesk.com/docs/en/client/linux/#permissions-issue',
            closeButton: true,
            closeOption: keyShowSelinuxHelpTip,
          ));
        }
      }
      if (bind.mainCurrentIsWayland()) {
        LinuxCards.add(buildInstallCard(
            "Warning", "wayland_experiment_tip", "", () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link: 'https://rustdesk.com/docs/en/client/linux/#x11-required'));
      } else if (bind.mainIsLoginWayland()) {
        LinuxCards.add(buildInstallCard("Warning",
            "Login screen using Wayland is not supported", "", () async {},
            marginTop: LinuxCards.isEmpty ? 20.0 : 5.0,
            help: 'Help',
            link: 'https://rustdesk.com/docs/en/client/linux/#login-screen'));
      }
      if (LinuxCards.isNotEmpty) {
        return Column(
          children: LinuxCards,
        );
      }
    }
    if (bind.isIncomingOnly()) {
      return Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton(
          onPressed: () {
            SystemNavigator.pop(); // Close the application
            // https://github.com/flutter/flutter/issues/66631
            if (isWindows) {
              exit(0);
            }
          },
          child: Text(translate('Quit')),
        ),
      ).marginAll(14);
    }
    return Container();
  }

  Widget buildInstallCard(String title, String content, String btnText,
      GestureTapCallback onPressed,
      {double marginTop = 20.0,
      String? help,
      String? link,
      bool? closeButton,
      String? closeOption}) {
    if (bind.mainGetBuildinOption(key: kOptionHideHelpCards) == 'Y' &&
        content != 'install_daemon_tip') {
      return const SizedBox();
    }
    void closeCard() async {
      if (closeOption != null) {
        await bind.mainSetLocalOption(key: closeOption, value: 'N');
        if (bind.mainGetLocalOption(key: closeOption) == 'N') {
          setState(() {
            isCardClosed = true;
          });
        }
      } else {
        setState(() {
          isCardClosed = true;
        });
      }
    }

    return Stack(
      children: [
        Container(
          margin: EdgeInsets.fromLTRB(
              0, marginTop, 0, bind.isIncomingOnly() ? marginTop : 0),
          child: Container(
              decoration: BoxDecoration(
                  gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  const Color.fromARGB(248, 36, 115, 168),
                  const Color.fromARGB(248, 55, 145, 230),
                ],
              )),
              padding: EdgeInsets.all(20),
              child: Column(
                  mainAxisAlignment: MainAxisAlignment.start,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: (title.isNotEmpty
                          ? <Widget>[
                              Center(
                                  child: Text(
                                translate(title),
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  shadows: [
                                    Shadow(
                                      color: Colors.black.withOpacity(0.45),
                                      blurRadius: 4,
                                      offset: const Offset(0, 1),
                                    ),
                                  ],
                                ),
                              ).marginOnly(bottom: 6)),
                            ]
                          : <Widget>[]) +
                      <Widget>[
                        if (content.isNotEmpty)
                          Text(
                            translate(content),
                            style: TextStyle(
                              height: 1.5,
                              color: Colors.white,
                              fontWeight: FontWeight.normal,
                              fontSize: 13,
                              shadows: [
                                Shadow(
                                  color: Colors.black.withOpacity(0.4),
                                  blurRadius: 3,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                          ).marginOnly(bottom: 20)
                      ] +
                      (btnText.isNotEmpty
                          ? <Widget>[
                              Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    _glassInstallCardActionButton(
                                      labelKey: btnText,
                                      onTap: onPressed,
                                    ),
                                  ])
                            ]
                          : <Widget>[]) +
                      (help != null
                          ? <Widget>[
                              Center(
                                  child: InkWell(
                                      onTap: () async =>
                                          await launchUrl(Uri.parse(link!)),
                                      child: Text(
                                        translate(help),
                                        style: TextStyle(
                                            decoration:
                                                TextDecoration.underline,
                                            color: Colors.white,
                                            fontSize: 12),
                                      )).marginOnly(top: 6)),
                            ]
                          : <Widget>[]))),
        ),
        if (closeButton != null && closeButton == true)
          Positioned(
            top: 18,
            right: 0,
            child: IconButton(
              icon: Icon(
                Icons.close,
                color: Colors.white,
                size: 20,
              ),
              onPressed: closeCard,
            ),
          ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), () async {
      await gFFI.serverModel.fetchID();
      final error = await bind.mainGetError();
      if (systemError != error) {
        systemError = error;
        setState(() {});
      }
      final v = await mainGetBoolOption(kOptionStopService);
      if (v != svcStopped.value) {
        svcStopped.value = v;
        setState(() {});
      }
      if (watchIsCanScreenRecording) {
        if (bind.mainIsCanScreenRecording(prompt: false)) {
          watchIsCanScreenRecording = false;
          setState(() {});
        }
      }
      if (watchIsProcessTrust) {
        if (bind.mainIsProcessTrusted(prompt: false)) {
          watchIsProcessTrust = false;
          setState(() {});
        }
      }
      if (watchIsInputMonitoring) {
        if (bind.mainIsCanInputMonitoring(prompt: false)) {
          watchIsInputMonitoring = false;
          // Do not notify for now.
          // Monitoring may not take effect until the process is restarted.
          // rustDeskWinManager.call(
          //     WindowType.RemoteDesktop, kWindowDisableGrabKeyboard, '');
          setState(() {});
        }
      }
      if (watchIsCanRecordAudio) {
        if (isMacOS) {
          Future.microtask(() async {
            if ((await osxCanRecordAudio() ==
                PermissionAuthorizeType.authorized)) {
              watchIsCanRecordAudio = false;
              setState(() {});
            }
          });
        } else {
          watchIsCanRecordAudio = false;
          setState(() {});
        }
      }
    });
    Get.put<RxBool>(svcStopped, tag: 'stop-service');
    rustDeskWinManager.registerActiveWindowListener(onActiveWindowChanged);

    screenToMap(window_size.Screen screen) => {
          'frame': {
            'l': screen.frame.left,
            't': screen.frame.top,
            'r': screen.frame.right,
            'b': screen.frame.bottom,
          },
          'visibleFrame': {
            'l': screen.visibleFrame.left,
            't': screen.visibleFrame.top,
            'r': screen.visibleFrame.right,
            'b': screen.visibleFrame.bottom,
          },
          'scaleFactor': screen.scaleFactor,
        };

    bool isChattyMethod(String methodName) {
      switch (methodName) {
        case kWindowBumpMouse:
          return true;
      }

      return false;
    }

    rustDeskWinManager.setMethodHandler((call, fromWindowId) async {
      if (!isChattyMethod(call.method)) {
        debugPrint(
            "[Main] call ${call.method} with args ${call.arguments} from window $fromWindowId");
      }
      if (call.method == kWindowMainWindowOnTop) {
        windowOnTop(null);
      } else if (call.method == kWindowRefreshCurrentUser) {
        gFFI.userModel.refreshCurrentUser();
      } else if (call.method == kWindowGetWindowInfo) {
        final screen = (await window_size.getWindowInfo()).screen;
        if (screen == null) {
          return '';
        } else {
          return jsonEncode(screenToMap(screen));
        }
      } else if (call.method == kWindowGetScreenList) {
        return jsonEncode(
            (await window_size.getScreenList()).map(screenToMap).toList());
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventShow) {
        await rustDeskWinManager.registerActiveWindow(call.arguments["id"]);
      } else if (call.method == kWindowEventHide) {
        await rustDeskWinManager.unregisterActiveWindow(call.arguments['id']);
      } else if (call.method == kWindowConnect) {
        await connectMainDesktop(
          call.arguments['id'],
          isFileTransfer: call.arguments['isFileTransfer'],
          isViewCamera: call.arguments['isViewCamera'],
          isTerminal: call.arguments['isTerminal'],
          isTcpTunneling: call.arguments['isTcpTunneling'],
          isRDP: call.arguments['isRDP'],
          password: call.arguments['password'],
          forceRelay: call.arguments['forceRelay'],
          connToken: call.arguments['connToken'],
        );
      } else if (call.method == kWindowBumpMouse) {
        return RdPlatformChannel.instance
            .bumpMouse(dx: call.arguments['dx'], dy: call.arguments['dy']);
      } else if (call.method == kWindowEventMoveTabToNewWindow) {
        final args = call.arguments.split(',');
        int? windowId;
        try {
          windowId = int.parse(args[0]);
        } catch (e) {
          debugPrint("Failed to parse window id '${call.arguments}': $e");
        }
        WindowType? windowType;
        try {
          windowType = WindowType.values.byName(args[3]);
        } catch (e) {
          debugPrint("Failed to parse window type '${call.arguments}': $e");
        }
        if (windowId != null && windowType != null) {
          await rustDeskWinManager.moveTabToNewWindow(
              windowId, args[1], args[2], windowType);
        }
      } else if (call.method == kWindowEventOpenMonitorSession) {
        final args = jsonDecode(call.arguments);
        final windowId = args['window_id'] as int;
        final peerId = args['peer_id'] as String;
        final display = args['display'] as int;
        final displayCount = args['display_count'] as int;
        final windowType = args['window_type'] as int;
        final screenRect = parseParamScreenRect(args);
        await rustDeskWinManager.openMonitorSession(
            windowId, peerId, display, displayCount, screenRect, windowType);
      } else if (call.method == kWindowEventRemoteWindowCoords) {
        final windowId = int.tryParse(call.arguments);
        if (windowId != null) {
          return jsonEncode(
              await rustDeskWinManager.getOtherRemoteWindowCoords(windowId));
        }
      }
    });
    _uniLinksSubscription = listenUniLinks();

    if (bind.isIncomingOnly()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateWindowSize();
      });
    }
  }

  _updateWindowSize() {
    RenderObject? renderObject = _childKey.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      if (size != imcomingOnlyHomeSize) {
        imcomingOnlyHomeSize = size;
        windowManager.setSize(getIncomingOnlyHomeSize());
      }
    }
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    Get.delete<RxBool>(tag: 'stop-service');
    _updateTimer?.cancel();
    super.dispose();
  }

  Widget buildPluginEntry() {
    final entries = PluginUiManager.instance.entries.entries;
    return Offstage(
      offstage: entries.isEmpty,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...entries.map((entry) {
            return entry.value;
          })
        ],
      ),
    );
  }
}

/// 버전 문자열 옆에서 [checkMDeskUpdate]를 수동 실행하는 새로고침 버튼
class _VersionLabelWithRefresh extends StatefulWidget {
  const _VersionLabelWithRefresh();

  @override
  State<_VersionLabelWithRefresh> createState() =>
      _VersionLabelWithRefreshState();
}

class _VersionLabelWithRefreshState extends State<_VersionLabelWithRefresh> {
  bool _checking = false;

  Future<void> _onRefresh() async {
    if (_checking) return;
    setState(() => _checking = true);
    final result = await checkMDeskUpdate();
    if (!mounted) return;
    setState(() => _checking = false);

    // 새 버전 알림은 상단 밴드/카드로만 안내 — 하단 스낵바는 쓰지 않음
    if (result == null && mounted) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      messenger?.showSnackBar(
        const SnackBar(content: Text('버전 확인에 실패했습니다. 네트워크를 확인해 주세요.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: bind.mainGetVersion(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        final textColor =
            Theme.of(context).textTheme.bodySmall?.color?.withOpacity(0.6);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'v${snapshot.data}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: textColor,
                  ),
            ),
            Tooltip(
              message: '최신 버전 확인',
              child: InkWell(
                onTap: _checking ? null : _onRefresh,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _checking
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: textColor,
                          ),
                        )
                      : Icon(
                          Icons.refresh,
                          size: 14,
                          color: textColor,
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

void setPasswordDialog({VoidCallback? notEmptyCallback}) async {
  final pw = await bind.mainGetPermanentPassword();
  final p0 = TextEditingController(text: pw);
  final p1 = TextEditingController(text: pw);
  var errMsg0 = "";
  var errMsg1 = "";
  final RxString rxPass = pw.trim().obs;
  final rules = [
    DigitValidationRule(),
    UppercaseValidationRule(),
    LowercaseValidationRule(),
    // SpecialCharacterValidationRule(),
    MinCharactersValidationRule(8),
  ];
  final maxLength = bind.mainMaxEncryptLen();

  gFFI.dialogManager.show((setState, close, context) {
    submit() {
      setState(() {
        errMsg0 = "";
        errMsg1 = "";
      });
      final pass = p0.text.trim();
      if (pass.isNotEmpty) {
        final Iterable violations = rules.where((r) => !r.validate(pass));
        if (violations.isNotEmpty) {
          setState(() {
            errMsg0 =
                '${translate('Prompt')}: ${violations.map((r) => r.name).join(', ')}';
          });
          return;
        }
      }
      if (p1.text.trim() != pass) {
        setState(() {
          errMsg1 =
              '${translate('Prompt')}: ${translate("The confirmation is not identical.")}';
        });
        return;
      }
      bind.mainSetPermanentPassword(password: pass);
      if (pass.isNotEmpty) {
        notEmptyCallback?.call();
      }
      close();
    }

    return CustomAlertDialog(
      title: Text(translate("Set Password")),
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 500),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              height: 8.0,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: translate('Password'),
                        errorText: errMsg0.isNotEmpty ? errMsg0 : null),
                    controller: p0,
                    autofocus: true,
                    onChanged: (value) {
                      rxPass.value = value.trim();
                      setState(() {
                        errMsg0 = '';
                      });
                    },
                    maxLength: maxLength,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(child: PasswordStrengthIndicator(password: rxPass)),
              ],
            ).marginSymmetric(vertical: 8),
            const SizedBox(
              height: 8.0,
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    obscureText: true,
                    decoration: InputDecoration(
                        labelText: translate('Confirmation'),
                        errorText: errMsg1.isNotEmpty ? errMsg1 : null),
                    controller: p1,
                    onChanged: (value) {
                      setState(() {
                        errMsg1 = '';
                      });
                    },
                    maxLength: maxLength,
                  ).workaroundFreezeLinuxMint(),
                ),
              ],
            ),
            const SizedBox(
              height: 8.0,
            ),
            Obx(() => Wrap(
                  runSpacing: 8,
                  spacing: 4,
                  children: rules.map((e) {
                    var checked = e.validate(rxPass.value.trim());
                    return Chip(
                        label: Text(
                          e.name,
                          style: TextStyle(
                              color: checked
                                  ? const Color(0xFF0A9471)
                                  : Color.fromARGB(255, 198, 86, 157)),
                        ),
                        backgroundColor: checked
                            ? const Color(0xFFD0F7ED)
                            : Color.fromARGB(255, 247, 205, 232));
                  }).toList(),
                ))
          ],
        ),
      ),
      actions: [
        dialogButton("Cancel", onPressed: close, isOutline: true),
        dialogButton("OK", onPressed: submit),
      ],
      onSubmit: submit,
      onCancel: close,
    );
  });
}
