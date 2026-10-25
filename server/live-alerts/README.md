# Relay live alerts

A small checker that runs for free on Cloudflare. Every minute it looks up
whether the streamers you picked in Relay are live, and when one goes live
it sends a notification to your phone through the free **ntfy** app.
Tapping the notification opens the stream in Relay.

Relay decides who to watch: your favorites are on by default, and the bell
on a channel turns alerts on or off for that streamer.

## One-time setup (about 10 minutes)

### 1. ntfy on your phone
1. Install **ntfy** from the App Store (free).
2. In Relay: **Settings → Live alerts**. Tap **Copy topic**.
3. In ntfy: tap **+**, paste the topic, keep the server as `ntfy.sh`,
   and subscribe. Allow notifications when asked.

### 2. The checker on Cloudflare
1. Make a free account at <https://dash.cloudflare.com>.
2. **Storage & Databases → KV → Create** a namespace called `relay-alerts`.
3. **Workers & Pages → Create → Create Worker** (start from "Hello World"),
   name it e.g. `relay-alerts`, and **Deploy**.
4. Open the worker → **Edit code**. Replace everything with the contents of
   `worker.js` from this folder, then **Deploy**.
5. Worker → **Settings → Bindings → Add → KV namespace**:
   variable name `ALERTS`, namespace `relay-alerts`. Save/deploy.
6. Worker → **Settings → Trigger events → Add → Cron trigger**:
   every minute (`* * * * *`). Save.
7. Copy the worker's address (it looks like
   `https://relay-alerts.<your-name>.workers.dev`).

### 3. Connect Relay
1. In Relay: **Settings → Live alerts**, paste the worker address.
2. Tap **Send test alert**. A notification should show up from ntfy.

That's it. A streamer you turn alerts on for will notify you the next time
they go live (not if they're already live when you turn it on).

## Optional: Kick through Kick's official API
Kick sometimes refuses requests from Cloudflare. If Kick alerts don't
arrive but Twitch ones do, create an app at <https://kick.com/settings/developer>
and add two **Secrets** to the worker (Settings → Variables and Secrets):
`KICK_CLIENT_ID` and `KICK_CLIENT_SECRET`.

## Notes
- Everything here fits Cloudflare's free plan. The worker only writes to
  storage when a stream starts or ends, or when Relay sends a new list.
- Your ntfy topic is a long random name only Relay and you know; it's also
  what the worker uses to keep your list. Anyone with the worker address and
  the topic could change your list, so keep the topic to yourself.
- A stream that drops and comes back within 10 minutes doesn't alert twice.
