import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

/// 설치 시「{$appName} 프린터」체크박스 표시. 필요 시 true로 복구.
const bool _kShowInstallPrinterOption = false;

class InstallPage extends StatefulWidget {
  const InstallPage({Key? key}) : super(key: key);

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _InstallPageState() {
    Get.put<DesktopTabController>(tabController);
    const label = "install";
    tabController.add(TabInfo(
        key: label,
        label: label,
        closable: false,
        page: _InstallPageBody(
          key: const ValueKey(label),
        )));
  }

  @override
  void dispose() {
    super.dispose();
    Get.delete<DesktopTabController>();
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(controller: tabController)),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  const _InstallPageBody({Key? key}) : super(key: key);

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = false.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;
  EnterpriseInstallConfig? enterpriseConfig;
  String enterpriseConfigSource = '';

  // todo move to theme.
  final buttonStyle = OutlinedButton.styleFrom(
    textStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
    padding: EdgeInsets.symmetric(vertical: 15, horizontal: 12),
  );

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    final installOptions = jsonDecode(bind.installInstallOptions());
    startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
    desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
    if (_kShowInstallPrinterOption) {
      printer.value = installOptions['PRINTER'] != '0';
    } else {
      printer.value = false;
    }
    _loadExistingEnterpriseConfig();
  }

  void _loadExistingEnterpriseConfig() {
    try {
      final decoded = jsonDecode(bind.mainGetOptionsSync());
      if (decoded is! Map) return;
      final idServer = decoded['custom-rendezvous-server']?.toString() ?? '';
      final relayServer = decoded['relay-server']?.toString() ?? '';
      final serverKey = decoded['key']?.toString() ?? '';
      if (idServer.isEmpty || relayServer.isEmpty || serverKey.isEmpty) return;
      enterpriseConfig = EnterpriseInstallConfig.fromValues(
        customerName: decoded['enterprise-customer-name']?.toString() ??
            translate('Existing enterprise configuration'),
        idServer: idServer,
        relayServer: relayServer,
        serverKey: serverKey,
        apiServer: decoded['api-server']?.toString() ?? '',
      );
      enterpriseConfigSource =
          decoded['enterprise-config-source']?.toString() ?? 'existing';
    } catch (_) {
      // Existing non-enterprise settings must not prevent installation.
    }
  }

  @override
  void initState() {
    windowManager.addListener(this);
    super.initState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() {
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  InkWell Option(RxBool option, {String label = ''}) {
    return InkWell(
      // todo mouseCursor: "SystemMouseCursors.forbidden" or no cursor on btnEnabled == false
      borderRadius: BorderRadius.circular(6),
      onTap: () => btnEnabled.value ? option.value = !option.value : null,
      child: Row(
        children: [
          Obx(
            () => Checkbox(
              visualDensity: VisualDensity(horizontal: -4, vertical: -4),
              value: option.value,
              onChanged: (v) =>
                  btnEnabled.value ? option.value = !option.value : null,
            ).marginOnly(right: 8),
          ),
          Expanded(
            child: Text(translate(label)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double em = 13;
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    return Scaffold(
        backgroundColor: null,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Installation'),
                  style: Theme.of(context).textTheme.headlineMedium),
              Row(
                children: [
                  Text('${translate('Installation Path')}:')
                      .marginOnly(right: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      readOnly: true,
                      decoration: InputDecoration(
                        contentPadding: EdgeInsets.all(0.75 * em),
                      ),
                    ).workaroundFreezeLinuxMint().marginOnly(right: 10),
                  ),
                  Obx(
                    () => OutlinedButton.icon(
                      icon: Icon(Icons.folder_outlined, size: 16),
                      onPressed: btnEnabled.value ? selectInstallPath : null,
                      style: buttonStyle,
                      label: Text(translate('Change Path')),
                    ),
                  )
                ],
              ).marginSymmetric(vertical: 2 * em),
              Option(startmenu, label: 'Create start menu shortcuts')
                  .marginOnly(bottom: 7),
              Option(desktopicon, label: 'Create desktop icon')
                  .marginOnly(bottom: 7),
              if (_kShowInstallPrinterOption)
                Option(printer, label: 'Install {$appName} Printer'),
              _buildEnterpriseConfigRow(),
              Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDarkTheme
                        ? Color.fromARGB(135, 87, 87, 90)
                        : Colors.grey[100],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline_rounded, size: 32)
                          .marginOnly(right: 16),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(translate('agreement_tip'))
                              .marginOnly(bottom: em),
                          InkWell(
                            hoverColor: Colors.transparent,
                            onTap: () => launchUrlString(
                                'https://www.mdesk.co.kr/#privacy-policy'),
                            child: Tooltip(
                              message:
                                  'https://www.mdesk.co.kr/#privacy-policy',
                              child: Row(children: [
                                Icon(Icons.launch_outlined, size: 16)
                                    .marginOnly(right: 5),
                                Text(
                                  translate('End-user license agreement'),
                                  style: const TextStyle(
                                      decoration: TextDecoration.underline),
                                )
                              ]),
                            ),
                          ),
                        ],
                      )
                    ],
                  )).marginSymmetric(vertical: 2 * em),
              Row(
                children: [
                  Expanded(
                    // NOT use Offstage to wrap LinearProgressIndicator
                    child: Obx(() => showProgress.value
                        ? LinearProgressIndicator().marginOnly(right: 10)
                        : Offstage()),
                  ),
                  Obx(
                    () => OutlinedButton.icon(
                      icon: Icon(Icons.close_rounded, size: 16),
                      label: Text(translate('Cancel')),
                      onPressed:
                          btnEnabled.value ? () => windowManager.close() : null,
                      style: buttonStyle,
                    ).marginOnly(right: 10),
                  ),
                  Obx(
                    () => ElevatedButton.icon(
                      icon: Icon(Icons.done_rounded, size: 16),
                      label: Text(translate('Accept and Install')),
                      onPressed: btnEnabled.value ? install : null,
                      style: buttonStyle,
                    ),
                  ),
                  Offstage(
                    offstage: bind.installShowRunWithoutInstall(),
                    child: Obx(
                      () => OutlinedButton.icon(
                        icon: Icon(Icons.screen_share_outlined, size: 16),
                        label: Text(translate('Run without install')),
                        onPressed: btnEnabled.value
                            ? () => bind.installRunWithoutInstall()
                            : null,
                        style: buttonStyle,
                      ).marginOnly(left: 10),
                    ),
                  ),
                ],
              )
            ],
          ).paddingSymmetric(horizontal: 4 * em, vertical: 3 * em),
        ));
  }

  Widget _buildEnterpriseConfigRow() {
    final config = enterpriseConfig;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Obx(
            () => OutlinedButton.icon(
              icon: const Icon(Icons.business_outlined, size: 17),
              onPressed:
                  btnEnabled.value ? _showEnterpriseConfigInputChoice : null,
              style: buttonStyle,
              label: Text(translate('Enterprise environment settings')),
            ),
          ),
          const SizedBox(width: 12),
          if (config == null)
            Text(
              translate('Not configured'),
              style: TextStyle(color: Colors.grey[600]),
            )
          else ...[
            const Icon(Icons.check_circle, size: 18, color: Colors.green),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${config.customerName} · ${translate('Configuration complete')}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${translate('ID Server')} ${config.idServer}  ·  '
                    '${translate('Relay Server')} ${config.relayServer}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[600]),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: translate('Clear'),
              onPressed: btnEnabled.value
                  ? () => setState(() {
                        enterpriseConfig = null;
                        enterpriseConfigSource = '';
                      })
                  : null,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showEnterpriseConfigInputChoice() async {
    final mode = await showDialog<_EnterpriseConfigInputMode>(
      context: this.context,
      builder: (dialogContext) => AlertDialog(
        title: Text(translate('Enterprise environment settings')),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(translate('Choose how to configure enterprise access.')),
              const SizedBox(height: 16),
              _enterpriseInputChoiceTile(
                context: dialogContext,
                icon: Icons.description_outlined,
                title: translate('Load JSON configuration'),
                subtitle: translate(
                    'Select the JSON configuration provided by your company.'),
                recommended: true,
                mode: _EnterpriseConfigInputMode.jsonFile,
              ),
              const SizedBox(height: 10),
              _enterpriseInputChoiceTile(
                context: dialogContext,
                icon: Icons.edit_outlined,
                title: translate('Enter manually'),
                subtitle: translate(
                    'Enter the enterprise server information manually.'),
                mode: _EnterpriseConfigInputMode.manual,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(translate('Cancel')),
          ),
        ],
      ),
    );

    if (!mounted || mode == null) return;
    if (mode == _EnterpriseConfigInputMode.jsonFile) {
      await _selectEnterpriseJson();
    } else {
      await _showManualEnterpriseConfigDialog();
    }
  }

  Widget _enterpriseInputChoiceTile({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required _EnterpriseConfigInputMode mode,
    bool recommended = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).pop(mode),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                      if (recommended) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            translate('Recommended'),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }

  Future<void> _selectEnterpriseJson() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;

      final selected = result.files.single;
      final contents = selected.bytes != null
          ? utf8.decode(selected.bytes!)
          : await File(selected.path!).readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('The JSON root must be an object.');
      }
      final config = EnterpriseInstallConfig.fromJson(decoded);
      if (!mounted) return;
      setState(() {
        enterpriseConfig = config;
        enterpriseConfigSource = 'json:${selected.name}';
      });
      showToast(
          '${translate('Enterprise configuration loaded')}: ${config.customerName}');
    } catch (e) {
      if (!mounted) return;
      await _showEnterpriseConfigError(e.toString());
    }
  }

  Future<void> _showManualEnterpriseConfigDialog() async {
    final current = enterpriseConfig;
    final customerController =
        TextEditingController(text: current?.customerName ?? '');
    final idServerController =
        TextEditingController(text: current?.idServer ?? '');
    final relayServerController =
        TextEditingController(text: current?.relayServer ?? '');
    final keyController = TextEditingController(text: current?.serverKey ?? '');
    final apiServerController =
        TextEditingController(text: current?.apiServer ?? '');

    final result = await showDialog<EnterpriseInstallConfig>(
      context: this.context,
      builder: (dialogContext) {
        String errorText = '';
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(translate('Enter enterprise information manually')),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _enterpriseTextField(
                      controller: customerController,
                      label: translate('Company name'),
                    ),
                    _enterpriseTextField(
                      controller: idServerController,
                      label: translate('ID Server'),
                      hint: '10.20.10.20:21116',
                    ),
                    _enterpriseTextField(
                      controller: relayServerController,
                      label: translate('Relay Server'),
                      hint: '10.20.10.21:21117',
                    ),
                    _enterpriseTextField(
                      controller: keyController,
                      label: translate('Server public key'),
                      maxLines: 2,
                    ),
                    _enterpriseTextField(
                      controller: apiServerController,
                      label: '${translate('API Server')} '
                          '(${translate('Optional')})',
                      hint: 'https://api.company.local',
                    ),
                    if (errorText.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        margin: const EdgeInsets.only(top: 4),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          errorText,
                          style: TextStyle(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(translate('Cancel')),
              ),
              ElevatedButton(
                onPressed: () {
                  try {
                    final config = EnterpriseInstallConfig.fromValues(
                      customerName: customerController.text,
                      idServer: idServerController.text,
                      relayServer: relayServerController.text,
                      serverKey: keyController.text,
                      apiServer: apiServerController.text,
                    );
                    Navigator.of(dialogContext).pop(config);
                  } catch (e) {
                    setDialogState(() => errorText = e.toString());
                  }
                },
                child: Text(translate('Apply')),
              ),
            ],
          ),
        );
      },
    );

    customerController.dispose();
    idServerController.dispose();
    relayServerController.dispose();
    keyController.dispose();
    apiServerController.dispose();

    if (!mounted || result == null) return;
    setState(() {
      enterpriseConfig = result;
      enterpriseConfigSource = 'manual';
    });
  }

  Widget _enterpriseTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ).workaroundFreezeLinuxMint().marginOnly(bottom: 12);
  }

  Future<void> _showEnterpriseConfigError(String message) {
    return showDialog<void>(
      context: this.context,
      builder: (dialogContext) => AlertDialog(
        title: Text(translate('Invalid enterprise configuration')),
        content: SelectableText(message.replaceFirst('FormatException: ', '')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(translate('OK')),
          ),
        ],
      ),
    );
  }

  Future<void> _persistEnterpriseConfig(EnterpriseInstallConfig config) async {
    final decoded = jsonDecode(await bind.mainGetOptions());
    final options = <String, String>{};
    if (decoded is Map) {
      decoded.forEach((key, value) {
        if (key is String && value is String) options[key] = value;
      });
    }
    options['custom-rendezvous-server'] = config.idServer;
    options['relay-server'] = config.relayServer;
    options['key'] = config.serverKey;
    if (config.apiServer.isEmpty) {
      options.remove('api-server');
    } else {
      options['api-server'] = config.apiServer;
    }
    options['enterprise-customer-name'] = config.customerName;
    options['enterprise-config-source'] = enterpriseConfigSource;
    await bind.mainSetOptions(json: jsonEncode(options));
  }

  Future<void> install() async {
    btnEnabled.value = false;
    showProgress.value = true;
    try {
      final config = enterpriseConfig;
      if (config != null) await _persistEnterpriseConfig(config);

      String args = '';
      if (startmenu.value) args += ' startmenu';
      if (desktopicon.value) args += ' desktopicon';
      if (printer.value) args += ' printer';
      await bind.installInstallMe(options: args, path: controller.text);
    } catch (e) {
      btnEnabled.value = true;
      showProgress.value = false;
      if (mounted) await _showEnterpriseConfigError(e.toString());
    }
  }

  void selectInstallPath() async {
    String? install_path = await FilePicker.platform
        .getDirectoryPath(initialDirectory: controller.text);
    if (install_path != null) {
      controller.text = join(install_path, await bind.mainGetAppName());
    }
  }
}

enum _EnterpriseConfigInputMode { jsonFile, manual }

class EnterpriseInstallConfig {
  final String customerName;
  final String idServer;
  final String relayServer;
  final String serverKey;
  final String apiServer;

  const EnterpriseInstallConfig({
    required this.customerName,
    required this.idServer,
    required this.relayServer,
    required this.serverKey,
    required this.apiServer,
  });

  factory EnterpriseInstallConfig.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != null && schemaVersion != 1) {
      throw const FormatException('Only schemaVersion 1 is supported.');
    }

    final customer = _mapValue(json['customer']);
    final servers = _mapValue(json['servers']);
    return EnterpriseInstallConfig.fromValues(
      customerName: _stringValue(customer['name'] ?? json['customerName']),
      idServer: _endpointValue(
        servers['idServer'] ?? json['idServer'],
        defaultPort: 21116,
        fieldName: 'ID Server',
      ),
      relayServer: _endpointValue(
        servers['relayServer'] ?? json['relayServer'],
        defaultPort: 21117,
        fieldName: 'Relay Server',
      ),
      serverKey: _stringValue(servers['serverKey'] ??
          servers['key'] ??
          json['serverKey'] ??
          json['key']),
      apiServer: _stringValue(servers['apiServer'] ?? json['apiServer'],
          required: false),
    );
  }

  factory EnterpriseInstallConfig.fromValues({
    required String customerName,
    required String idServer,
    required String relayServer,
    required String serverKey,
    required String apiServer,
  }) {
    final normalizedCustomer = customerName.trim();
    if (normalizedCustomer.isEmpty) {
      throw FormatException(translate('Company name is required.'));
    }
    final normalizedId =
        _normalizeEndpoint(idServer, 21116, fieldName: 'ID Server');
    final normalizedRelay =
        _normalizeEndpoint(relayServer, 21117, fieldName: 'Relay Server');
    final normalizedKey = serverKey.trim();
    if (normalizedKey.isEmpty) {
      throw FormatException(translate('Server public key is required.'));
    }
    try {
      final standardKey =
          normalizedKey.replaceAll('-', '+').replaceAll('_', '/');
      if (base64Decode(base64.normalize(standardKey)).length != 32) {
        throw FormatException(translate('Server public key must be 32 bytes.'));
      }
    } catch (e) {
      if (e is FormatException &&
          e.message == translate('Server public key must be 32 bytes.')) {
        rethrow;
      }
      throw FormatException(
          translate('Server public key is not valid Base64.'));
    }

    final normalizedApi = apiServer.trim();
    if (normalizedApi.isNotEmpty) {
      final uri = Uri.tryParse(normalizedApi);
      if (uri == null ||
          !const ['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty) {
        throw FormatException(
            translate('API Server must be a valid HTTP or HTTPS URL.'));
      }
    }

    return EnterpriseInstallConfig(
      customerName: normalizedCustomer,
      idServer: normalizedId,
      relayServer: normalizedRelay,
      serverKey: normalizedKey,
      apiServer: normalizedApi,
    );
  }

  static Map<String, dynamic> _mapValue(dynamic value) {
    return value is Map<String, dynamic> ? value : const <String, dynamic>{};
  }

  static String _stringValue(dynamic value, {bool required = true}) {
    final result = value?.toString().trim() ?? '';
    if (required && result.isEmpty) {
      throw FormatException(translate('A required field is missing.'));
    }
    return result;
  }

  static String _endpointValue(
    dynamic value, {
    required int defaultPort,
    required String fieldName,
  }) {
    if (value is Map) {
      final host = value['host']?.toString().trim() ?? '';
      final port = value['port']?.toString().trim() ?? '$defaultPort';
      return _normalizeEndpoint('$host:$port', defaultPort,
          fieldName: fieldName);
    }
    return _normalizeEndpoint(value?.toString() ?? '', defaultPort,
        fieldName: fieldName);
  }

  static String _normalizeEndpoint(
    String value,
    int defaultPort, {
    required String fieldName,
  }) {
    var endpoint = value.trim();
    if (endpoint.isEmpty) {
      throw FormatException(
          '${translate(fieldName)} ${translate('is required.')}');
    }
    if (endpoint.contains('://') || endpoint.contains(RegExp(r'\s'))) {
      throw FormatException(
          '${translate(fieldName)}: ${translate('Use the host:port format.')}');
    }

    String host;
    int port;
    if (endpoint.startsWith('[')) {
      final closing = endpoint.indexOf(']');
      if (closing <= 1) {
        throw FormatException(
            '${translate(fieldName)}: ${translate('Invalid IPv6 address.')}');
      }
      host = endpoint.substring(0, closing + 1);
      if (endpoint.length == closing + 1) {
        port = defaultPort;
      } else {
        if (endpoint[closing + 1] != ':') {
          throw FormatException(
              '${translate(fieldName)}: ${translate('Use the host:port format.')}');
        }
        port = int.tryParse(endpoint.substring(closing + 2)) ?? 0;
      }
    } else {
      final firstColon = endpoint.indexOf(':');
      final lastColon = endpoint.lastIndexOf(':');
      if (firstColon != lastColon) {
        throw FormatException(
            '${translate(fieldName)}: ${translate('IPv6 addresses must be enclosed in [].')}');
      }
      if (lastColon > 0) {
        host = endpoint.substring(0, lastColon);
        port = int.tryParse(endpoint.substring(lastColon + 1)) ?? 0;
      } else {
        host = endpoint;
        port = defaultPort;
      }
    }
    if (host.isEmpty || port < 1 || port > 65535) {
      throw FormatException(
          '${translate(fieldName)}: ${translate('Invalid host or port.')}');
    }
    return '$host:$port';
  }
}
