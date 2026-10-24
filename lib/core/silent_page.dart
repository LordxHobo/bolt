import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Keeps a hidden web page (twitch.tv / kick.com, used only to make requests)
/// from ever playing video. Without this, a stream preview on those pages
/// could start and iOS would show it full screen over Relay.
final silentPageScript = UserScript(
  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
  source: r'''
(function () {
  if (window.__relaySilent) return;
  window.__relaySilent = true;
  const proto = HTMLMediaElement.prototype;
  proto.play = function () {
    try { this.muted = true; this.pause(); } catch (e) {}
    return Promise.reject(new DOMException('Playback disabled', 'NotAllowedError'));
  };
  const quiet = (el) => {
    try {
      el.muted = true;
      el.autoplay = false;
      el.preload = 'none';
      el.pause();
      el.removeAttribute('src');
      if (el.load) el.load();
    } catch (e) {}
  };
  const sweep = (root) => {
    if (!root || !root.querySelectorAll) return;
    if (root instanceof HTMLMediaElement) quiet(root);
    root.querySelectorAll('video, audio').forEach(quiet);
  };
  // Anything that still starts (e.g. autoplay) is stopped right away.
  for (const type of ['play', 'playing', 'loadeddata']) {
    document.addEventListener(type, (e) => {
      const el = e.target;
      if (el instanceof HTMLMediaElement) { try { el.muted = true; el.pause(); } catch (x) {} }
    }, true);
  }
  new MutationObserver((changes) => {
    for (const c of changes) c.addedNodes.forEach(sweep);
  }).observe(document, { childList: true, subtree: true });
})();
''',
);
