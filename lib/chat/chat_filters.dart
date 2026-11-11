import '../core/settings.dart';
import 'chat_models.dart';

/// Your chat filters: hide bots, mute words or people, highlight keywords.
/// Only on your phone; nobody else sees a difference.
class ChatFilters {
  ChatFilters._();

  /// Common chat bots on Twitch and Kick.
  static const bots = {
    'nightbot', 'streamelements', 'moobot', 'fossabot', 'streamlabs', 'wizebot',
    'sery_bot', 'soundalerts', 'pokemoncommunitygame', 'kofistreambot', 'commanderroot',
    'botrix', 'botrixoficial', 'kickbot', 'kicbot', 'blerp', 'own3d', 'creatisbot',
    'lumiastream', 'streamlootsbot', 'tangiabot', 'frostytoolsdotcom', 'buttsbot',
    'supibot', 'potatbotat', 'fyowbot', 'songlistbot', 'dixperbro', 'kickbotai',
  };

  static final _cache = <String, RegExp>{};

  /// Whether [text] has [word] in it (whole word, any case; phrases match
  /// anywhere).
  static bool _has(String text, String word) {
    final w = word.toLowerCase();
    if (w.isEmpty) return false;
    final re = _cache.putIfAbsent(
      w,
      () => RegExp('(^|[^\\p{L}\\p{N}_])${RegExp.escape(w)}(\$|[^\\p{L}\\p{N}_])', unicode: true),
    );
    return re.hasMatch(text);
  }

  static bool hidden(ChatMessage m, Settings s) {
    final login = m.authorLogin.toLowerCase();
    if (login.isEmpty) return false;
    if (s.mutedUsers.contains(login)) return true;
    if (s.hideBots && (bots.contains(login) || m.roles.contains('bot'))) return true;
    if (s.mutedWords.isEmpty) return false;
    final text = m.plainText.toLowerCase();
    return s.mutedWords.any((w) => _has(text, w));
  }

  static bool highlighted(ChatMessage m, Settings s) {
    if (s.highlightWords.isEmpty || m.authorLogin.isEmpty) return false;
    final text = m.plainText.toLowerCase();
    return s.highlightWords.any((w) => _has(text, w));
  }
}
