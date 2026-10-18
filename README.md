# Relay

A phone app (Android + iOS) for watching **Twitch and Kick** in one place, with
**7TV emotes** in chat and **TwitchAdSolutions** ad blocking on Twitch.

- Favorites from both platforms in one list, with live status, viewers and titles
- Twitch: live channels you follow (after logging in)
- Twitch playback through Twitch's own player, with TwitchAdSolutions' `vaft`
  script injected at page start, the same way a userscript manager runs it
- Kick playback through the native video player (ExoPlayer / AVPlayer)
- Native chat for both: 7TV global + channel emotes (including zero-width
  emotes), Twitch and Kick emotes, emote autocomplete, recent message history,
  deleted/banned message handling, pause-on-scroll
- Log in and chat on Twitch and Kick
- Landscape mode with a collapsible chat column

## How the ad blocking works

The Twitch player runs in a WebView. Before Twitch's page code runs, Relay
injects a TwitchAdSolutions userscript, which swaps ad segments for an ad-free
backup stream (see the upstream repo for details). You choose the script in
Settings → Twitch ad blocking:

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
- Kick has no quality picker yet (the player adapts automatically). Twitch's
  player has its own quality menu.
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
  ui/                       screens and widgets
assets/adblock/             bundled TwitchAdSolutions scripts + MIT license
assets/icon/                app icon (icon.png for iOS, icon_foreground.png for Android)
tool/configure_platforms.dart   patches the generated android/ and ios/ folders
```

Not affiliated with Twitch, Kick or 7TV.
