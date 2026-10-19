# Relay

A phone app (Android + iOS) for watching **Twitch and Kick** in one place, with
**7TV emotes** in chat and **TwitchAdSolutions** ad blocking on Twitch.

- Home screen menu: **Favorites**, **Following** (both platforms, with an
  All / Twitch / Kick filter; multistreams show once), **Kick** and **Twitch**.
  Live favorites come first, then by viewers. It reopens on the view you used last.
- Twitch and Kick playback in the native video player (AVPlayer / ExoPlayer)
  through Relay's local relay, which keeps you close to live and removes
  Twitch ads (ported from TwitchAdSolutions' `vaft`)
- Latency readout on the video and a low-latency mode that catches up
  automatically (both in Settings → Player)
- iPhone: picture-in-picture when you swipe home while a stream plays, and a
  full screen button that rotates the video even with rotation lock on
- Twitch's own web player is still available as a fallback, with the
  TwitchAdSolutions scripts injected
- Native chat for both: 7TV global + channel emotes (including zero-width
  emotes), Twitch and Kick emotes, emote autocomplete, recent message history,
  deleted/banned message handling, pause-on-scroll
- Log in and chat on Twitch and Kick
- Landscape mode with a collapsible chat column

## How the player and ad blocking work

Relay runs a tiny HTTP server on the phone (127.0.0.1 only). The video player
loads the stream from it, and Relay fetches the real playlists from Twitch or
Kick and rewrites them:

- **Lower latency.** Phones play Twitch's stock playlists about 15-20 s behind
  live. Relay serves a short playlist with tight segment timing, adds Twitch's
  early ("prefetch") segments, and in low-latency mode speeds playback up
  slightly (1.1× or 1.25×) until you're back to about 3.5 s behind. Past 30 s
  behind it reloads.
- **Ad removal (Twitch).** This is the same idea as TwitchAdSolutions' `vaft`:
  segments marked as ads are dropped and the gap is filled from an ad-free
  backup stream (Twitch's embed/popout/autoplay players), matched by time. If
  no backup is ad-free either, the player waits for the break to end
  ("Ad break, waiting for the stream").
- **Latency readout.** Video segments pass through the relay too, so Relay
  knows the newest piece the player downloaded and its timestamp. "Xs behind
  live" is that piece's age plus however much video is buffered ahead of the
  playhead.

### Web player fallback

Settings → Player → **Twitch web player** switches Twitch back to Twitch's own
player in a WebView. Before Twitch's page code runs, Relay injects a
TwitchAdSolutions userscript. You choose the script in Settings → Twitch ad
blocking:

| Option | What it is |
| --- | --- |
| vaft (bundled, default) | `vaft` 37.0.0 from [pixeltris/TwitchAdSolutions](https://github.com/pixeltris/TwitchAdSolutions) |
| vaft fork (online) | [0rpi/twitch-adblock-userscript](https://github.com/0rpi/twitch-adblock-userscript), a maintained fork, downloaded and cached |
| video-swap-new (bundled) | The other TwitchAdSolutions script |
| Custom URL | Any userscript URL |
| Off | No ad blocking |

TwitchAdSolutions was archived by its author on 2026-03-05, so the bundled
script won't get fixes. If ads start leaking through, switch to the fork.

## Building it (no Mac or Flutter install needed)

The workflow in `.github/workflows/build.yml` builds both apps on GitHub's
servers.

1. Create an empty repository on GitHub (private is fine) and push this folder
   to it. The folder is already a git repository with one commit:
   ```sh
   git remote add origin https://github.com/<you>/relay.git
   git push -u origin main
   ```
2. Open the repo's **Actions** tab. The **Build** workflow starts on every push
   to `main`; you can also run it by hand with **Run workflow**.
3. When it finishes, download the artifacts at the bottom of the run page:
   - `relay-android` → `app-release.apk`
   - `relay-ios` → `relay-unsigned.ipa`

Private repos get free GitHub Actions minutes each month; macOS minutes count
10×, and one iOS build takes roughly 10–15 minutes.

## Installing on iPhone

The IPA is unsigned, so a sideloading tool signs it with your Apple ID:

1. Install **[Sideloadly](https://sideloadly.io)** (Windows or macOS) or
   **[AltStore](https://altstore.io)** (AltServer runs on Windows).
2. Plug in your iPhone, drag `relay-unsigned.ipa` into the tool, sign in with
   your Apple ID, and install.
3. On the phone, turn on **Settings → Privacy & Security → Developer Mode**
   when iOS asks, and trust your Apple ID under
   **Settings → General → VPN & Device Management**.

With a free Apple ID the app has to be re-signed every 7 days (AltStore or
**[SideStore](https://sidestore.io)** can do this automatically), and you can
have up to 3 sideloaded apps. A paid Apple Developer account ($99/year) makes
the signature last a year.

## Installing on Android

Copy `app-release.apk` to the phone and open it. Android will ask you to allow
installs from that app (your browser or file manager) the first time.

Each CI build is signed with a fresh debug key, so to update you may need to
uninstall the old version first. To avoid that, add your own signing key
(see Flutter's [Android signing guide](https://docs.flutter.dev/deployment/android#sign-the-app)).

## Setting up logins (optional)

Watching and reading chat work without any setup. Logging in (to send chat
messages, and to see the Twitch channels you follow) needs your own free
developer apps, because Twitch and Kick both require one. You then paste the
IDs into **Settings → Developer apps** in Relay.

### Twitch

1. Go to <https://dev.twitch.tv/console/apps> → **Register Your Application**.
2. Name: anything. OAuth Redirect URL: `http://localhost`.
   Category: Application Integration. **Client Type: Public.**
3. Copy the **Client ID** into Relay → Settings → Twitch Client ID.
4. Tap **Log in** next to Twitch. Relay shows a code; open twitch.tv/activate,
   enter it, and approve.

Public apps have no client secret, so nothing secret is stored in the app.

### Kick

1. Turn on two-factor authentication on your Kick account (Kick requires it
   for developer apps).
2. Go to <https://kick.com/settings/developer> and create an app.
   Redirect URL: `http://localhost/auth/callback`.
   Enable the `user:read` and `chat:write` scopes.
3. Copy the **Client ID** and **Client Secret** into Relay → Settings.
4. Tap **Log in** next to Kick and sign in on the page that opens.

The Kick client secret is stored in the phone's secure storage (Keychain /
Android Keystore).

### Kick follow list

Kick's official API can't list the channels you follow yet, so Relay uses the
one kick.com's website uses. In Settings → **kick.com (follow list)**, tap
**Sign in**, log in on the kick.com page, then tap **Done**. This is separate
from the developer-app login above and needs no Client ID. It's unofficial,
so it may stop working if Kick changes its site.

## Building locally (optional)

With Flutter 3.47 or newer installed:

```sh
flutter create --platforms=android,ios --org io.github.relayapp --project-name relay .
dart run tool/configure_platforms.dart
flutter run
```

`flutter create` only adds the missing native folders; it won't touch the
existing `lib/` code.

## Known limits

- **Kick chat** moved from Pusher to Kick's own Centrifugo server on
  2026-10-13. Relay uses the new connection flow the Kick website uses; it's
  not an official API, so it may change again.
- **Kick's website API** (channel info, playback URL, chat history) is behind
  Cloudflare. When Cloudflare blocks a plain request, Relay repeats it inside a
  hidden WebView with kick.com open, which behaves like a normal browser.
- The relay player picks the best quality by default; change it with the
  quality button on the video. It doesn't switch quality by itself when your
  connection drops.
- Twitch ad removal hasn't been tested much against Twitch's newest ad
  methods. If ads get through, try the web player fallback with the vaft fork.
- No picture-in-picture or background audio yet.
- Twitch chat badges are shown as simple icons (broadcaster, mod, VIP, sub)
  rather than Twitch's badge images.

## Project layout

```
lib/
  main.dart                 app entry + theme
  core/                     models, settings, shared HTTP helpers
  twitch/                   GQL/Helix API, device-code login, IRC chat, ad-block scripts
  kick/                     website API (+ Cloudflare fallback), OAuth login, Centrifugo chat
  chat/                     chat models, 7TV, chat controller
  player/                   local relay: HLS parsing/stitching, Twitch/Kick sources
packages/relay_native_player/   the iPhone player (AVPlayer + picture-in-picture)
  ui/                       screens and widgets
assets/adblock/             bundled TwitchAdSolutions scripts + MIT license
assets/icon/                app icon (icon.png for iOS, icon_foreground.png for Android)
tool/configure_platforms.dart   patches the generated android/ and ios/ folders
```

Not affiliated with Twitch, Kick or 7TV.
