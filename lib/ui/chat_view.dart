import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/services.dart';
import 'settings_screen.dart';
import 'widgets.dart';

class ChatView extends StatefulWidget {
  const ChatView({super.key, required this.controller, required this.platform});

  final ChatController controller;
  final StreamPlatform platform;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  final _input = TextEditingController();
  final _focus = FocusNode();
  bool _sending = false;
  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _input.addListener(_updateSuggestions);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    // The list is reversed: offset 0 is the newest message.
    widget.controller.setPaused(_scroll.hasClients && _scroll.offset > 40);
  }

  void _jumpToLatest() {
    widget.controller.setPaused(false);
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  void _updateSuggestions() {
    final text = _input.text;
    final sel = _input.selection;
    final cursor = sel.isValid ? sel.baseOffset : text.length;
    final before = text.substring(0, math.max(0, math.min(cursor, text.length)));
    final word = before.split(RegExp(r'\s')).last;
    List<String> next = const [];
    if (word.length >= 2) {
      final lower = word.toLowerCase();
      next = widget.controller.emoteNames
          .where((n) => n.toLowerCase().startsWith(lower))
          .take(12)
          .toList();
    }
    if (next.length != _suggestions.length || !next.every(_suggestions.contains)) {
      setState(() => _suggestions = next);
    }
  }

  void _applySuggestion(String emote) {
    final text = _input.text;
    final sel = _input.selection;
    final cursor = math.max(0, math.min(sel.isValid ? sel.baseOffset : text.length, text.length));
    final before = text.substring(0, cursor);
    final start = before.lastIndexOf(RegExp(r'\s')) + 1;
    final after = text.substring(cursor);
    final replaced = '${text.substring(0, start)}$emote ';
    _input.value = TextEditingValue(
      text: replaced + after,
      selection: TextSelection.collapsed(offset: replaced.length),
    );
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.controller.send(text);
      _input.clear();
      _jumpToLatest();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([widget.controller, Services.settings]),
      builder: (context, _) {
        final c = widget.controller;
        final scale = Services.settings.chatTextScale;
        final showTime = Services.settings.showTimestamps;
        return Column(
          children: [
            if (c.status != ChatConnection.connected) _StatusBar(controller: c),
            Expanded(
              child: Stack(
                children: [
                  ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: c.messages.length,
                    itemBuilder: (context, i) => ChatLine(
                      message: c.messages[i],
                      scale: scale,
                      showTimestamp: showTime,
                    ),
                  ),
                  if (c.isPaused)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 8,
                      child: Center(
                        child: FilledButton.tonalIcon(
                          onPressed: _jumpToLatest,
                          icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                          label: Text(c.pendingCount > 0
                              ? '${c.pendingCount} new messages'
                              : 'Back to live chat'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (_suggestions.isNotEmpty) _suggestionBar(),
            _inputBar(c),
          ],
        );
      },
    );
  }

  Widget _suggestionBar() {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final s in _suggestions)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
              child: ActionChip(
                label: Text(s),
                visualDensity: VisualDensity.compact,
                onPressed: () => _applySuggestion(s),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inputBar(ChatController c) {
    final theme = Theme.of(context);
    if (!c.canSend) {
      return Material(
        color: theme.colorScheme.surfaceContainer,
        child: InkWell(
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                'Sign in to ${widget.platform.label} in Settings to chat',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
              ),
            ),
          ),
        ),
      );
    }
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 500,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    isDense: true,
                    counterText: '',
                    hintText: 'Send a message',
                    filled: true,
                    fillColor: theme.colorScheme.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
              ),
              IconButton(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.send_rounded, color: widget.platform.color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.controller});
  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    final error = controller.status == ChatConnection.error;
    final text = controller.statusText ??
        (controller.status == ChatConnection.connecting ? 'Connecting…' : 'Disconnected');
    return Container(
      width: double.infinity,
      color: error ? Colors.red.withValues(alpha: 0.25) : Colors.white10,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// One chat message.
class ChatLine extends StatelessWidget {
  const ChatLine({
    super.key,
    required this.message,
    this.scale = 1,
    this.showTimestamp = false,
  });

  final ChatMessage message;
  final double scale;
  final bool showTimestamp;

  static const _roleIcons = <String, (IconData, Color)>{
    'broadcaster': (Icons.videocam_rounded, Color(0xFFE91916)),
    'moderator': (Icons.shield_rounded, Color(0xFF00AD03)),
    'vip': (Icons.diamond_rounded, Color(0xFFE005B9)),
    'og': (Icons.workspace_premium_rounded, Color(0xFF00D1FF)),
    'founder': (Icons.workspace_premium_rounded, Color(0xFFFFB800)),
    'subscriber': (Icons.star_rounded, Color(0xFF9146FF)),
    'staff': (Icons.build_rounded, Color(0xFFFFFFFF)),
    'verified': (Icons.verified_rounded, Color(0xFF53FC18)),
    'partner': (Icons.verified_rounded, Color(0xFF9146FF)),
  };

  /// Raises the lightness of dark name colors so they read on a dark background.
  static Color readable(Color? c, Color fallback) {
    if (c == null) return fallback;
    final hsl = HSLColor.fromColor(c);
    return hsl.lightness < 0.55 ? hsl.withLightness(0.62).toColor() : c;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 14 * scale,
      height: 1.45,
    );
    final emoteHeight = 28.0 * scale;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);

    if (message.systemText != null && message.fragments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(message.systemText!,
            style: base.copyWith(color: muted, fontStyle: FontStyle.italic)),
      );
    }

    final nameColor = readable(message.authorColor, theme.colorScheme.primary);
    final spans = <InlineSpan>[];
    if (showTimestamp) {
      final t = message.timestamp;
      spans.add(TextSpan(
        text: '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} ',
        style: base.copyWith(color: muted, fontSize: 12 * scale),
      ));
    }
    for (final role in message.roles) {
      final icon = _roleIcons[role];
      if (icon == null) continue;
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.only(right: 3),
          child: Icon(icon.$1, size: 15 * scale, color: icon.$2),
        ),
      ));
    }
    spans.add(TextSpan(
      text: message.author,
      style: base.copyWith(color: nameColor, fontWeight: FontWeight.w700),
    ));
    spans.add(TextSpan(text: message.isAction ? ' ' : ': ', style: base));

    final bodyStyle = message.isAction
        ? base.copyWith(color: nameColor, fontStyle: FontStyle.italic)
        : base;
    if (message.deleted) {
      spans.add(TextSpan(
        text: '<message deleted>',
        style: base.copyWith(color: muted, fontStyle: FontStyle.italic),
      ));
    } else {
      for (final f in message.fragments) {
        switch (f) {
          case TextFragment(:final text):
            spans.add(TextSpan(text: text, style: bodyStyle));
          case EmoteFragment(:final emote, :final overlays):
            spans.add(WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _EmoteImage(emote: emote, overlays: overlays, height: emoteHeight),
            ));
        }
      }
    }

    return Container(
      color: message.systemText != null ? Colors.white.withValues(alpha: 0.05) : null,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Opacity(
        opacity: message.isHistory ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.systemText != null)
              Text(message.systemText!, style: base.copyWith(color: muted, fontSize: 12 * scale)),
            Text.rich(TextSpan(children: spans)),
          ],
        ),
      ),
    );
  }
}

class _EmoteImage extends StatelessWidget {
  const _EmoteImage({required this.emote, required this.overlays, required this.height});

  final Emote emote;
  final List<Emote> overlays;
  final double height;

  double _widthFor(Emote e) {
    final w = e.width, h = e.height;
    if (w != null && h != null && w > 0 && h > 0) return height * w / h;
    return height;
  }

  Widget _image(Emote e) => CachedNetworkImage(
        imageUrl: e.url,
        height: height,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => SizedBox(width: _widthFor(e), height: height),
        errorWidget: (_, __, ___) => Text(e.name),
      );

  @override
  Widget build(BuildContext context) {
    final image = Tooltip(message: emote.name, child: _image(emote));
    if (overlays.isEmpty) return image;
    return Stack(
      alignment: Alignment.center,
      children: [
        image,
        for (final o in overlays) _image(o),
      ],
    );
  }
}
