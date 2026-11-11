import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import 'chat_view.dart';

/// Shows a reply conversation. Returns the message to reply to when you
/// tap Reply (or a message in it), else null.
Future<ChatMessage?> showThread(
  BuildContext context, {
  required ChatController controller,
  required String rootId,
}) =>
    showModalBottomSheet<ChatMessage>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.95,
        builder: (context, scroll) => ListenableBuilder(
          // New replies show up while it's open.
          listenable: controller,
          builder: (context, _) => _Thread(controller: controller, rootId: rootId, scroll: scroll),
        ),
      ),
    );

class _Thread extends StatelessWidget {
  const _Thread({required this.controller, required this.rootId, required this.scroll});

  final ChatController controller;
  final String rootId;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final messages = controller.thread(rootId);
    final hasRoot = messages.isNotEmpty && messages.first.id == rootId;
    // The first message arrived before Bolt opened the chat: show what the
    // replies quote of it.
    ChatReply? quoted;
    if (!hasRoot) {
      for (final m in messages) {
        if (m.reply?.parentId == rootId) {
          quoted = m.reply;
          break;
        }
      }
    }
    final canSend = controller.canSend;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              Text('Thread', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text('${messages.length} ${messages.length == 1 ? 'message' : 'messages'}',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted)),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            controller: scroll,
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              if (quoted != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: quoted.parentName ?? quoted.parentLogin ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: ': ${quoted.parentBody ?? ''}'),
                    ]),
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  ),
                ),
              if (!hasRoot && quoted == null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
                  child: Text('The first message was sent before you opened the chat.',
                      style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                ),
              for (final m in messages)
                ChatLine(
                  message: m,
                  badges: controller.badges,
                  showTimestamp: true,
                  // Tap a message to reply to it.
                  onTap: canSend ? () => Navigator.of(context).pop(m) : null,
                ),
            ],
          ),
        ),
        if (canSend && messages.isNotEmpty)
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).pop(messages.last),
                  icon: const Icon(Icons.reply_rounded),
                  label: const Text('Reply in thread'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
