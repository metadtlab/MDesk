import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../mobile/pages/home_page_shared.dart';
import 'chat_view.dart';

enum ChatPageType {
  mobileMain,
  desktopCM,
}

class ChatPage extends StatelessWidget implements PageShape {
  late final ChatModel chatModel;
  final ChatPageType? type;

  ChatPage({ChatModel? chatModel, this.type}) {
    this.chatModel = chatModel ?? gFFI.chatModel;
  }

  @override
  final title = translate("Chat");

  @override
  final icon = unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum);

  @override
  final appBarActions = [
    PopupMenuButton<MessageKey>(
        tooltip: "",
        icon: unreadTopRightBuilder(gFFI.chatModel.mobileUnreadSum,
            icon: Icon(Icons.group)),
        itemBuilder: (context) {
          // only mobile need [appBarActions], just bind gFFI.chatModel
          final chatModel = gFFI.chatModel;
          return chatModel.messages.entries.map((entry) {
            final key = entry.key;
            final user = entry.value.chatUser;
            final client = gFFI.serverModel.clients
                .firstWhereOrNull((e) => e.id == key.connId);
            final connected =
                gFFI.serverModel.clients.any((e) => e.id == key.connId);
            return PopupMenuItem<MessageKey>(
              child: Row(
                children: [
                  Icon(
                          key.isOut
                              ? Icons.call_made_rounded
                              : Icons.call_received_rounded,
                          color: MyTheme.accent)
                      .marginOnly(right: 6),
                  Text("${user.firstName}   ${user.id}"),
                  if (connected)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color.fromARGB(255, 46, 205, 139)),
                    ).marginSymmetric(horizontal: 2),
                  if (client != null)
                    unreadMessageCountBuilder(client.unreadChatMessageCount)
                        .marginOnly(left: 4)
                ],
              ),
              value: key,
            );
          }).toList();
        },
        onSelected: (key) {
          gFFI.chatModel.changeCurrentKey(key);
        })
  ];

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: chatModel,
      child: Consumer<ChatModel>(
        builder: (context, chatModel, child) {
          final readOnly = type == ChatPageType.mobileMain &&
                  (chatModel.currentKey.connId == ChatModel.clientModeID ||
                      gFFI.serverModel.clients.every((e) =>
                          e.id != chatModel.currentKey.connId ||
                          chatModel.currentUser == null)) ||
              type == ChatPageType.desktopCM &&
                  gFFI.serverModel.clients
                          .firstWhereOrNull(
                              (e) => e.id == chatModel.currentKey.connId)
                          ?.disconnected ==
                      true;
          final peer = chatModel.currentUser;
          return Column(children: [
            if (type == ChatPageType.desktopCM)
              MDeskChatHeader(
                  title: peer?.firstName?.isNotEmpty == true
                      ? peer!.firstName!
                      : translate('Chat'),
                  subtitle: peer?.id),
            Expanded(
              child: SelectionArea(
                child: MDeskChatView(
                  currentUser: chatModel.me,
                  messages:
                      chatModel.messages[chatModel.currentKey]?.chatMessages ??
                          [],
                  onSend: chatModel.send,
                  textController: chatModel.textController,
                  focusNode: chatModel.inputNode,
                  inputHint: translate('Write a message'),
                  sendLabel: translate('Send'),
                  disconnectedLabel: translate('Disconnected'),
                  latestLabel: translate('Scroll to bottom'),
                  conversationKey: chatModel.currentKey,
                  readOnly: readOnly,
                ).workaroundFreezeLinuxMint(),
              ),
            ),
          ]);
        },
      ),
    );
  }
}
