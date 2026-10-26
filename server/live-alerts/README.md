# Bolt live alerts

A small checker that runs for free on Cloudflare. Every minute it looks up
whether the streamers you picked in Bolt are live, and when one goes live
it sends a notification to your iPhone through the free **Bark** app.
Tapping the notification opens the stream in Bolt.

Bolt decides who to watch: your favorites are on by default, and the bell
on a channel turns alerts on or off for that streamer.

## One-time setup

### 1. Bark on your phone
1. Install **Bark** from the App Store (free) and open it; allow
   notifications.
2. It shows an example address like `https://api.day.app/AbCdEf123456/...`.
   The part after `api.day.app/` (up to the next `/`) is **your key**.

### 2. The checker on Cloudflare
1. Make a free account at <https://dash.cloudflare.com>.
2. **Compute → Workers & Pages → Create → Start with Hello World!**, name
   it `relay-alerts`, **Deploy**. Its address ends in `.workers.dev`.
3. Open the worker → **Edit code**, replace everything with `worker.js` from
   this folder, **Deploy**.
4. **Storage & databases → KV → Create**, name it `relay-alerts`.
5. Worker → **Settings → Bindings → Add → KV namespace**: variable name
   `ALERTS`, namespace `relay-alerts`. Deploy.
6. Worker → **Settings → Variables and Secrets → Add**: environment
   **Production**, key `BARK_KEY`, value your Bark key, **Secret** ticked.
   Deploy.
7. Worker → **Settings → Trigger events / Cron Triggers → Add**: every
   minute (`* * * * *`).

### 3. Connect Bolt
1. In Bolt: **Settings → Live alerts**, paste the worker address.
2. Tap **Send test alert**. A notification should show up from Bark.

A streamer you turn alerts on for will notify you the next time they go
live (not if they're already live when you turn it on).

## Using ntfy instead of Bark
Leave `BARK_KEY` out and subscribe to Bolt's private key (Settings → Live
alerts → Copy) in the ntfy app. Note that ntfy.sh limits senders per
internet address and Cloudflare's addresses are shared, so without a paid
ntfy plan (token in the `NTFY_TOKEN` secret) it usually refuses with "429".

## Optional: Kick through Kick's official API
Kick sometimes refuses requests from Cloudflare. If Kick alerts don't
arrive but Twitch ones do, create an app at <https://kick.com/settings/developer>
and add two **Secrets** to the worker: `KICK_CLIENT_ID` and
`KICK_CLIENT_SECRET`.

## Notes
- Everything here fits Cloudflare's free plan. The worker only writes to
  storage when a stream starts or ends, or when Bolt sends a new list.
- Bolt's private key is what the worker uses to keep your list. Anyone
  with the worker address and that key could change your list, so keep it
  to yourself (same for your Bark key).
- A stream that drops and comes back within 10 minutes doesn't alert twice.
