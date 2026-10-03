import 'dart:math' as math;

import 'package:dash_chat_2/dash_chat_2.dart';
import 'package:flutter/material.dart';

/// Shared by the remote-session popup and the connection-manager chat panel.
class MDeskChatColors {
  static const background = Color(0xFFB9CFDF);
  static const header = Color(0xFFC5D8E6);
  static const outgoing = Color(0xFFFEE500);
  static const text = Color(0xFF263541);
  static const muted = Color(0xFF536B7C);
}

class MDeskChatHeader extends StatelessWidget {
  const MDeskChatHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.only(left: 14, right: 6),
      decoration: const BoxDecoration(
        color: MDeskChatColors.header,
        border: Border(bottom: BorderSide(color: Color(0x1A536B7C))),
      ),
      child: Row(children: [
        const Icon(Icons.chat_bubble_outline_rounded,
            size: 20, color: MDeskChatColors.text),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: MDeskChatColors.text,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              if (subtitle?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: MDeskChatColors.muted, fontSize: 11)),
                ),
            ],
          ),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

class MDeskChatView extends StatelessWidget {
  const MDeskChatView({
    super.key,
    required this.currentUser,
    required this.messages,
    required this.onSend,
    required this.textController,
    required this.focusNode,
    required this.inputHint,
    required this.sendLabel,
    required this.disconnectedLabel,
    required this.latestLabel,
    this.conversationKey,
    this.readOnly = false,
  });

  final ChatUser currentUser;
  final List<ChatMessage> messages;
  final ValueChanged<ChatMessage> onSend;
  final TextEditingController textController;
  final FocusNode focusNode;
  final String inputHint;
  final String sendLabel;
  final String disconnectedLabel;
  final String latestLabel;
  final Object? conversationKey;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: MDeskChatColors.background,
      child: Column(children: [
        Expanded(
          child: Stack(children: [
            Column(children: [
              Expanded(
                child: _ChatHistory(
                  key: ValueKey(conversationKey ?? currentUser.id),
                  currentUser: currentUser,
                  messages: messages,
                  latestLabel: latestLabel,
                ),
              ),
              if (!readOnly)
                InputToolbar(
                  currentUser: currentUser,
                  onSend: onSend,
                  inputOptions: InputOptions(
                    textController: textController,
                    focusNode: focusNode,
                    alwaysShowSend: true,
                    inputMaxLines: 4,
                    inputToolbarMargin: EdgeInsets.zero,
                    inputToolbarPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    inputToolbarStyle: const BoxDecoration(
                      color: Colors.white,
                      border: Border(top: BorderSide(color: Color(0xFFE0E7EB))),
                    ),
                    inputTextStyle: const TextStyle(
                        fontSize: 14, height: 1.4, color: MDeskChatColors.text),
                    cursorStyle: const CursorStyle(color: MDeskChatColors.text),
                    inputDecoration: InputDecoration(
                      hintText: inputHint,
                      hintStyle: const TextStyle(color: Color(0xFF96A4AE)),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 2, vertical: 12),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    sendButtonBuilder: (send) => Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: textController,
                        builder: (context, value, _) => Tooltip(
                          message: sendLabel,
                          child: SizedBox(
                            width: 40,
                            height: 38,
                            child: TextButton(
                              onPressed:
                                  value.text.trim().isEmpty ? null : send,
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                backgroundColor: MDeskChatColors.outgoing,
                                foregroundColor: MDeskChatColors.text,
                                disabledBackgroundColor:
                                    const Color(0xFFF2F4F5),
                                disabledForegroundColor:
                                    const Color(0xFFAFBBC3),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8)),
                              ),
                              child: const Icon(Icons.arrow_upward_rounded,
                                  size: 21),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]),
            if (messages.isEmpty)
              Positioned.fill(
                bottom: readOnly ? 0 : 64,
                child: IgnorePointer(
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.chat_bubble_outline_rounded,
                          size: 34, color: Color(0x80536B7C)),
                      const SizedBox(height: 12),
                      Text(inputHint,
                          style: const TextStyle(
                              fontSize: 13, color: MDeskChatColors.muted)),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        if (readOnly)
          Container(
            width: double.infinity,
            color: const Color(0xFFF5F7F8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Text(disconnectedLabel,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: MDeskChatColors.muted, fontSize: 12)),
          ),
      ]),
    );
  }
}

class _ChatHistory extends StatefulWidget {
  const _ChatHistory(
      {super.key,
      required this.currentUser,
      required this.messages,
      required this.latestLabel});
  final ChatUser currentUser;
  // ChatModel stores newest first; render oldest first for a top-aligned room.
  final List<ChatMessage> messages;
  final String latestLabel;

  @override
  State<_ChatHistory> createState() => _ChatHistoryState();
}

class _ChatHistoryState extends State<_ChatHistory> {
  final _scroll = ScrollController();
  ChatMessage? _latest;
  bool _showLatest = false;

  @override
  void initState() {
    super.initState();
    _latest = widget.messages.firstOrNull;
    _scroll.addListener(_onScroll);
    _scrollToLatest(animate: false);
  }

  @override
  void didUpdateWidget(covariant _ChatHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    final latest = widget.messages.firstOrNull;
    if (!identical(latest, _latest)) {
      _latest = latest;
      if (!_scroll.hasClients || _scroll.position.extentAfter < 64) {
        _scrollToLatest();
      }
    }
  }

  void _onScroll() {
    final show = _scroll.hasClients && _scroll.position.extentAfter > 120;
    if (show != _showLatest) setState(() => _showLatest = show);
  }

  void _scrollToLatest({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final bottom = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(bottom,
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(bottom);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusScope.of(context).unfocus(),
          child: ListView.builder(
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.only(bottom: 14),
            itemCount: widget.messages.length,
            itemBuilder: (context, index) {
              final i = widget.messages.length - 1 - index;
              final message = widget.messages[i];
              final previous = i + 1 < widget.messages.length
                  ? widget.messages[i + 1]
                  : null;
              final afterDate = previous == null ||
                  !DateUtils.isSameDay(previous.createdAt, message.createdAt);
              final startsGroup = afterDate ||
                  previous.user.id != message.user.id ||
                  message.createdAt.difference(previous.createdAt).inMinutes >=
                      5;
              return Column(children: [
                if (afterDate) _DateChip(date: message.createdAt),
                _MessageBubble(
                    message: message,
                    isOwn: message.user.id == widget.currentUser.id,
                    startsGroup: startsGroup),
              ]);
            },
          ),
        ),
        if (_showLatest)
          Positioned(
            right: 12,
            bottom: 12,
            child: Material(
              color: Colors.white,
              elevation: 2,
              shape: const CircleBorder(),
              child: IconButton(
                tooltip: widget.latestLabel,
                onPressed: _scrollToLatest,
                constraints:
                    const BoxConstraints.tightFor(width: 34, height: 34),
                padding: EdgeInsets.zero,
                icon: const Icon(Icons.keyboard_arrow_down_rounded,
                    color: MDeskChatColors.muted, size: 22),
              ),
            ),
          ),
      ]);
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.date});
  final DateTime date;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 20, 12, 16),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: const Color(0x22536B7C),
                borderRadius: BorderRadius.circular(20)),
            child: Text(MaterialLocalizations.of(context).formatFullDate(date),
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: MDeskChatColors.text, fontSize: 11)),
          ),
        ),
      );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.isOwn,
    required this.startsGroup,
  });
  final ChatMessage message;
  final bool isOwn;
  final bool startsGroup;

  @override
  Widget build(BuildContext context) {
    final name = message.user.firstName ?? message.user.id;
    final time = Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 2),
      child: Text(
        MaterialLocalizations.of(context)
            .formatTimeOfDay(TimeOfDay.fromDateTime(message.createdAt)),
        style: const TextStyle(fontSize: 10, color: MDeskChatColors.muted),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(14, startsGroup ? 12 : 5, 14, 0),
      child: LayoutBuilder(builder: (context, constraints) {
        return Column(
          crossAxisAlignment:
              isOwn ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isOwn && startsGroup && name.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, color: MDeskChatColors.text)),
              ),
            Row(
              mainAxisAlignment:
                  isOwn ? MainAxisAlignment.end : MainAxisAlignment.start,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (isOwn) time,
                Flexible(
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: math.max(
                          40,
                          math.min(constraints.maxWidth * .76,
                              constraints.maxWidth - 72)),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: isOwn ? MDeskChatColors.outgoing : Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft:
                            Radius.circular(!isOwn && startsGroup ? 3 : 11),
                        topRight:
                            Radius.circular(isOwn && startsGroup ? 3 : 11),
                        bottomLeft: const Radius.circular(11),
                        bottomRight: const Radius.circular(11),
                      ),
                      boxShadow: const [
                        BoxShadow(
                            color: Color(0x0C263541),
                            offset: Offset(0, 1),
                            blurRadius: 1),
                      ],
                    ),
                    child: Text(message.text,
                        style: const TextStyle(
                            color: MDeskChatColors.text,
                            fontSize: 14,
                            height: 1.45)),
                  ),
                ),
                if (!isOwn) time,
              ],
            ),
          ],
        );
      }),
    );
  }
}
