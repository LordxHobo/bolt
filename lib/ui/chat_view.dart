import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../chat/badges.dart';
import '../chat/chat_controller.dart';
import '../chat/chat_models.dart';
import '../core/models.dart';
import '../core/services.dart';
import '../kick/kick_follows.dart';
import 'settings_screen.dart';
import 'thread_sheet.dart';
import 'user_card.dart';
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

  /// The message you're replying to (shown above the input).
  ChatMessage? _replyTo;
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
    if (word.startsWith('@')) {
      next = _mentionSuggestions(word.substring(1));
    } else if (word.length >= 2) {
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

  /// Puts `@name ` in your message (from a chatter's profile).
  void _mention(String name) {
    final text = _input.text;
    final add = '@$name ';
    _input.text = text.isEmpty || text.endsWith(' ') ? '$text$add' : '$text $add';
    _input.selection = TextSelection.collapsed(offset: _input.text.length);
    _focus.requestFocus();
  }

  /// Your names on Twitch and Kick (lowercase), to highlight messages that
  /// mention you.
  Set<String> get _myNames => {
        if (Services.twitch.login != null) Services.twitch.login!.toLowerCase(),
        if (KickFollows.username != null) KickFollows.username!.toLowerCase(),
      };

  /// Names for "@": people who chatted most recently first, plus the
  /// streamer. "@" alone shows the most recent chatters; letters after it
  /// narrow it down (names starting with them first, then containing them).
  List<String> _mentionSuggestions(String typed) {
    final query = typed.toLowerCase();
    final mine = {
      Services.twitch.login?.toLowerCase(),
      KickFollows.username?.toLowerCase(),
    };
    final seen = <String>{};
    final names = <String>[];
    void add(String name) {
      final key = name.toLowerCase();
      if (key.isEmpty || mine.contains(key) || !seen.add(key)) return;
      names.add(name);
    }

    final messages = widget.controller.messages;
    for (var i = 0; i < messages.length && i < 400; i++) {
      final m = messages[i];
      if (m.systemText != null && m.author.isEmpty) continue;
      // The display name, unless it's in another script (then the login,
      // which is what Twitch matches on).
      final display = m.author.toLowerCase() == m.authorLogin.toLowerCase() ? m.author : m.authorLogin;
      add(display);
    }
    add(widget.controller.channel.displayName);

    final starts = <String>[];
    final contains = <String>[];
    for (final n in names) {
      final lower = n.toLowerCase();
      if (lower.startsWith(query)) {
        starts.add(n);
      } else if (query.length >= 2 && lower.contains(query)) {
        contains.add(n);
      }
    }
    final result = [...starts, ...contains].take(8).map((n) => '@$n').toList();
    // Already typed out exactly: nothing left to suggest.
    if (result.length == 1 && result.first.toLowerCase() == '@$query') return const [];
    return result;
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
      await widget.controller.send(text, replyTo: _replyTo);
      _input.clear();
      _replyTo = null;
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
                    // Scrolling the chat puts the keyboard away.
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: c.messages.length,
                    itemBuilder: (context, i) => ChatLine(
                      message: c.messages[i],
                      badges: c.badges,
                      onTap: c.messages[i].authorLogin.isEmpty
                          ? null
                          : () => showUserCard(context,
                              controller: c, message: c.messages[i], onMention: _mention),
                      onLongPress: c.messages[i].authorLogin.isEmpty
                          ? null
                          : () => _messageActions(c, c.messages[i]),
                      onThread: c.messages[i].reply == null
                          ? null
                          : () => _openThread(c, c.threadOf(c.messages[i])),
                      myNames: _myNames,
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
            if (_replyTo != null && c.canSend) _replyBar(_replyTo!),
            _inputBar(c),
          ],
        );
      },
    );
  }

  void _startReply(ChatMessage m) {
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  /// Long-press on a message.
  Future<void> _messageActions(ChatController c, ChatMessage m) async {
    final inThread = m.reply != null || c.thread(m.id).length > 1;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ChatLine(message: m, badges: c.badges),
            ),
            if (c.canSend)
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Reply'),
                onTap: () => Navigator.pop(context, 'reply'),
              ),
            if (inThread)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('View thread'),
                onTap: () => Navigator.pop(context, 'thread'),
              ),
            ListTile(
              leading: const Icon(Icons.person_outline_rounded),
              title: Text('View ${m.author}'),
              onTap: () => Navigator.pop(context, 'profile'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_rounded),
              title: const Text('Copy message'),
              onTap: () => Navigator.pop(context, 'copy'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'reply':
        _startReply(m);
      case 'thread':
        _openThread(c, c.threadOf(m));
      case 'profile':
        await showUserCard(context, controller: c, message: m, onMention: _mention);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: m.plainText));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Copied')));
        }
    }
  }

  Future<void> _openThread(ChatController c, String rootId) async {
    final replyTo = await showThread(context, controller: c, rootId: rootId);
    if (replyTo != null && mounted) _startReply(replyTo);
  }

  Widget _replyBar(ChatMessage m) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    return TextFieldTapRegion(
      child: Container(
        color: theme.colorScheme.surfaceContainer,
        padding: const EdgeInsets.fromLTRB(14, 6, 4, 0),
        child: Row(
          children: [
            Icon(Icons.reply_rounded, size: 16, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: 'Replying to ', style: TextStyle(color: muted)),
                  TextSpan(
                    text: '@${m.author}',
                    style: TextStyle(
                      color: ChatLine.readable(m.authorColor, theme.colorScheme.primary),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  TextSpan(text: ': ${m.plainText}', style: TextStyle(color: muted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Cancel reply',
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() => _replyTo = null),
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionBar() {
    // Counts as part of the text field, so picking an emote keeps typing.
    return TextFieldTapRegion(
      child: _suggestionList(),
    );
  }

  Widget _suggestionList() {
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
                  // Tapping anywhere else (chat, video, header) puts the
                  // keyboard away. iOS doesn't do that by itself.
                  onTapOutside: (_) => _focus.unfocus(),
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
              // Part of the text field's tap area, so sending keeps the
              // keyboard up for the next message.
              TextFieldTapRegion(
                child: IconButton(
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(Icons.send_rounded, color: widget.platform.color),
              ),
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
    this.myNames = const {},
    this.badges,
    this.onTap,
    this.onLongPress,
    this.onThread,
  });

  final ChatMessage message;

  /// Badge pictures for this channel.
  final ChatBadges? badges;

  /// Tapping the message (opens the chatter's profile).
  final VoidCallback? onTap;

  /// Long-pressing it (reply, thread, copy).
  final VoidCallback? onLongPress;

  /// Tapping the "replying to" line above it (opens the conversation).
  final VoidCallback? onThread;
  final double scale;
  final bool showTimestamp;

  /// Your usernames (lowercase); messages mentioning them are highlighted.
  final Set<String> myNames;

  /// Whether the message mentions one of [myNames] (with or without @), and
  /// isn't your own.
  bool get mentionsMe {
    if (myNames.isEmpty || message.deleted) return false;
    if (myNames.contains(message.authorLogin.toLowerCase())) return false;
    final text = message.fragments.whereType<TextFragment>().map((f) => f.text).join(' ').toLowerCase();
    for (final name in myNames) {
      if (name.isEmpty) continue;
      final pattern = RegExp('(^|[^a-z0-9_])@?${RegExp.escape(name)}(\$|[^a-z0-9_])');
      if (pattern.hasMatch(text)) return true;
    }
    return false;
  }

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
    'sub_gifter': (Icons.card_giftcard_rounded, Color(0xFF53FC18)),
    'bot': (Icons.smart_toy_rounded, Color(0xFF9E9E9E)),
  };

  /// One badge: the platform's picture when there is one, else Bolt's icon.
  static Widget? badgeWidget(ChatBadge b, ChatBadges? store, double size) {
    final look = store?.lookFor(b);
    final url = look?.imageUrl;
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url,
        width: size,
        height: size,
        fit: BoxFit.contain,
        fadeInDuration: Duration.zero,
        placeholder: (_, __) => SizedBox(width: size, height: size),
        errorWidget: (_, __, ___) => SizedBox(width: size, height: size),
      );
    }
    final icon = _roleIcons[b.set];
    if (icon == null) return null;
    return Icon(icon.$1, size: size, color: icon.$2);
  }

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
    if (message.badges.isNotEmpty) {
      for (final b in message.badges) {
        final w = badgeWidget(b, badges, 18 * scale);
        if (w == null) continue;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(padding: const EdgeInsets.only(right: 3), child: w),
        ));
      }
    } else {
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

    final mention = mentionsMe;
    final line = Container(
      // Messages that mention you: tinted, with a bar on the left, like
      // Twitch and Kick do.
      decoration: BoxDecoration(
        color: mention
            ? const Color(0xFFE91916).withValues(alpha: 0.18)
            : message.systemText != null
                ? Colors.white.withValues(alpha: 0.05)
                : null,
        border: mention
            ? const Border(left: BorderSide(color: Color(0xFFE91916), width: 3))
            : null,
      ),
      padding: EdgeInsets.fromLTRB(mention ? 9 : 12, 2, 12, 2),
      child: Opacity(
        opacity: message.isHistory ? 0.7 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.systemText != null)
              Text(message.systemText!, style: base.copyWith(color: muted, fontSize: 12 * scale)),
            if (message.reply case final r?)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onThread,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 1),
                  child: Row(
                    children: [
                      Icon(Icons.subdirectory_arrow_right_rounded, size: 13 * scale, color: muted),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          'Replying to @${r.parentName ?? r.parentLogin ?? '…'}'
                          '${(r.parentBody ?? '').isEmpty ? '' : ': ${r.parentBody}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: base.copyWith(color: muted, fontSize: 12 * scale),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Text.rich(TextSpan(children: spans)),
          ],
        ),
      ),
    );
    if (onTap == null && onLongPress == null) return line;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: line,
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
