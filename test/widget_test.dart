import 'package:flutter_test/flutter_test.dart';
import 'package:relay/chat/chat_models.dart';
import 'package:relay/core/models.dart';
import 'package:relay/kick/kick_api.dart';
import 'package:relay/twitch/twitch_chat.dart';

void main() {
  test('IRC PRIVMSG with tags parses', () {
    final msg = IrcMessage.parse(
        r'@badges=moderator/1;color=#FF0000;display-name=Some\sOne;emotes=25:6-10;id=abc '
        ':someone!someone@someone.tmi.twitch.tv PRIVMSG #chan :hello Kappa there')!;
    expect(msg.command, 'PRIVMSG');
    expect(msg.nick, 'someone');
    expect(msg.tags['display-name'], 'Some One');
    expect(msg.params, ['#chan', 'hello Kappa there']);
  });

  test('ChannelRef accepts links', () {
    expect(ChannelRef(StreamPlatform.twitch, 'https://www.twitch.tv/XQC').login, 'xqc');
    expect(ChannelRef(StreamPlatform.kick, 'kick.com/trainwreckstv').login, 'trainwreckstv');
    expect(ChannelRef(StreamPlatform.kick, '@Someone ').login, 'someone');
  });

  test('Kick inline emotes become fragments', () {
    final f = parseKickContent('hi [emote:37226:KEKW] lol');
    expect(f.length, 3);
    expect((f[1] as EmoteFragment).emote.url, 'https://files.kick.com/emotes/37226/fullsize');
  });

  test('7TV words are replaced and zero-width emotes stack', () {
    const base = Emote(name: 'PepeLaugh', url: 'u1', source: EmoteSource.sevenTv);
    const zw = Emote(name: 'RainTime', url: 'u2', source: EmoteSource.sevenTv, zeroWidth: true);
    final out = applyEmotes(
      [const TextFragment('lol PepeLaugh RainTime ok')],
      {'PepeLaugh': base, 'RainTime': zw},
    );
    final emotes = out.whereType<EmoteFragment>().toList();
    expect(emotes.length, 1);
    expect(emotes.first.overlays.single.name, 'RainTime');
    final text = out.whereType<TextFragment>().map((t) => t.text).join('|');
    expect(text, 'lol | ok');
  });

  test('Kick channel JSON parses', () {
    final info = KickApi.parseChannel({
      'id': 12,
      'user_id': 34,
      'slug': 'abc',
      'playback_url': 'https://x/y.m3u8',
      'user': {'username': 'Abc', 'profile_pic': 'https://p'},
      'chatroom': {'id': 56},
      'livestream': {
        'is_live': true,
        'session_title': 'Title',
        'viewer_count': 1500,
        'thumbnail': {'url': 'https://t'},
        'categories': [
          {'name': 'Just Chatting'}
        ],
      },
    }, fallbackSlug: 'abc');
    expect(info.userId, '34');
    expect(info.kickChatroomId, 56);
    expect(info.isLive, true);
    expect(info.category, 'Just Chatting');
    expect(info.thumbnailUrl, 'https://t');
  });
}
