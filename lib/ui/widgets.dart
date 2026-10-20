import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/models.dart';

/// The Twitch or Kick logo. [compact] is the small version that sits on
/// avatars and next to names, on a dark tile so it stands out on any picture.
class PlatformBadge extends StatelessWidget {
  const PlatformBadge(this.platform, {super.key, this.compact = false});

  final StreamPlatform platform;
  final bool compact;

  static String assetFor(StreamPlatform p) => switch (p) {
        StreamPlatform.twitch => 'assets/platform/twitch.png',
        StreamPlatform.kick => 'assets/platform/kick.png',
      };

  @override
  Widget build(BuildContext context) {
    final logo = Image.asset(
      assetFor(platform),
      filterQuality: FilterQuality.medium,
      semanticLabel: platform.label,
    );
    if (!compact) return SizedBox(width: 24, height: 24, child: logo);
    return Container(
      width: 18,
      height: 18,
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: const Color(0xFF16161A),
        borderRadius: BorderRadius.circular(5),
      ),
      child: logo,
    );
  }
}

class ChannelAvatar extends StatelessWidget {
  const ChannelAvatar({super.key, required this.info, this.size = 44});

  final ChannelInfo info;
  final double size;

  @override
  Widget build(BuildContext context) {
    final url = info.avatarUrl;
    final fallback = Container(
      width: size,
      height: size,
      color: info.platform.color.withValues(alpha: 0.25),
      alignment: Alignment.center,
      child: Text(
        info.displayName.isEmpty ? '?' : info.displayName[0].toUpperCase(),
        style: TextStyle(fontSize: size * 0.4, fontWeight: FontWeight.w700),
      ),
    );
    return ClipOval(
      child: SizedBox(
        width: size,
        height: size,
        child: url == null
            ? fallback
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, __) => fallback,
                errorWidget: (_, __, ___) => fallback,
              ),
      ),
    );
  }
}

/// One row in the home list.
class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.info,
    required this.onTap,
    this.onLongPress,
    this.isFavorite = false,
    this.loading = false,
    this.alsoOn,
  });

  final ChannelInfo info;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isFavorite;
  final bool loading;

  /// Set when this streamer is also followed on the other platform.
  final StreamPlatform? alsoOn;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);
    final subtitle = <String>[
      if (info.isLive && info.category != null) info.category!,
      if (!info.isLive) loading ? 'Checking…' : 'Offline',
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Opacity(
                  opacity: info.isLive ? 1 : 0.55,
                  child: ChannelAvatar(info: info),
                ),
                Positioned(
                  right: -4,
                  bottom: -2,
                  child: PlatformBadge(info.platform, compact: true),
                ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          info.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (alsoOn != null) ...[
                        const SizedBox(width: 6),
                        PlatformBadge(alsoOn!, compact: true),
                      ],
                      if (isFavorite) ...[
                        const SizedBox(width: 4),
                        Icon(Icons.star_rounded, size: 15, color: Colors.amber.shade400),
                      ],
                    ],
                  ),
                  if (info.isLive && info.title != null)
                    Text(
                      info.title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted),
                    ),
                ],
              ),
            ),
            if (info.isLive && info.viewers != null) ...[
              const SizedBox(width: 10),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.circle, size: 8, color: Color(0xFFFF4D4D)),
                  const SizedBox(width: 5),
                  Text(formatViewers(info.viewers),
                      style: theme.textTheme.labelMedium),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text.toUpperCase(),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

void showError(BuildContext context, Object error) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(error.toString())));
}
