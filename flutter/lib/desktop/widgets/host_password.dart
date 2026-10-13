import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/animated_rotation_widget.dart';

/// The home panel's password stays private until explicitly revealed.
class HostPassword extends StatefulWidget {
  const HostPassword({
    super.key,
    required this.controller,
    required this.enabled,
    required this.showOneTime,
    required this.onRefresh,
    required this.onCopied,
    this.onSettings,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool showOneTime;
  final VoidCallback onRefresh;
  final VoidCallback onCopied;
  final VoidCallback? onSettings;

  @override
  State<HostPassword> createState() => _HostPasswordState();
}

class _HostPasswordState extends State<HostPassword> {
  bool _visible = false;
  late String _password;

  bool get _hasPassword =>
      _password.isNotEmpty &&
      _password != '-' &&
      _password != translate('Generating ...');

  bool get _available => widget.enabled && widget.showOneTime && _hasPassword;

  @override
  void initState() {
    super.initState();
    _password = widget.controller.text;
    widget.controller.addListener(_passwordChanged);
  }

  void _passwordChanged() {
    if (_password == widget.controller.text) return;
    setState(() {
      _password = widget.controller.text;
      _visible = false;
    });
  }

  @override
  void didUpdateWidget(HostPassword oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_passwordChanged);
      widget.controller.addListener(_passwordChanged);
      _password = widget.controller.text;
      _visible = false;
    }
    if (!_available) _visible = false;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_passwordChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final visible = _available && _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: AutoSizeText(
                translate('One-time Password'),
                style: TextStyle(
                    fontSize: 14, color: textColor?.withValues(alpha: 0.5)),
                maxLines: 1,
              ),
            ),
            if (widget.showOneTime)
              IconButton(
                tooltip: translate(visible ? 'Hide password' : 'Show password'),
                icon: Icon(visible
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined),
                iconSize: 18,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                onPressed: _available
                    ? () => setState(() => _visible = !_visible)
                    : null,
              ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: GestureDetector(
                onDoubleTap: visible
                    ? () {
                        Clipboard.setData(ClipboardData(text: _password));
                        widget.onCopied();
                      }
                    : null,
                child: TextFormField(
                  controller: widget.controller,
                  readOnly: true,
                  obscureText: _hasPassword && !visible,
                  enableInteractiveSelection: visible,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    filled: true,
                    fillColor: Colors.transparent,
                    hoverColor: Colors.transparent,
                    contentPadding: EdgeInsets.only(top: 14, bottom: 10),
                  ),
                  style: TextStyle(
                      fontSize: 15,
                      color: widget.enabled
                          ? textColor
                          : Theme.of(context).disabledColor),
                ).workaroundFreezeLinuxMint(),
              ),
            ),
            if (widget.showOneTime)
              Padding(
                padding: const EdgeInsets.only(right: 8, top: 4),
                child: IgnorePointer(
                  ignoring: !_available,
                  child: AnimatedRotationWidget(
                    onPressed: () {
                      if (!_available) return;
                      setState(() => _visible = false);
                      widget.onRefresh();
                    },
                    child: Tooltip(
                      message: translate('Refresh Password'),
                      child: Icon(Icons.refresh,
                          size: 22,
                          color: _available
                              ? textColor
                              : Theme.of(context).disabledColor),
                    ),
                  ),
                ),
              ),
            if (widget.onSettings != null)
              IconButton(
                tooltip: translate('Change Password'),
                icon: const Icon(Icons.edit),
                iconSize: 22,
                padding: const EdgeInsets.only(top: 4),
                constraints:
                    const BoxConstraints.tightFor(width: 30, height: 30),
                onPressed: widget.onSettings,
              ),
          ],
        ),
      ],
    );
  }
}
