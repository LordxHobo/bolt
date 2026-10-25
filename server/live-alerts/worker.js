// Relay live alerts: a tiny Cloudflare Worker that checks every minute who
// is live and sends a notification through ntfy when a streamer goes live.
//
// Relay tells it which streamers to watch (PUT /config/<topic>); <topic> is
// the private ntfy topic Relay made for you, so it also works as the key.
// Setup steps: see README.md next to this file.
//
// Bindings (Worker settings):
//   ALERTS             KV namespace (required)
//   NTFY_SERVER        optional, default https://ntfy.sh
//   KICK_CLIENT_ID     optional, a Kick developer app; used if kick.com's
//   KICK_CLIENT_SECRET own site API refuses the Worker
//
// Free-plan friendly: KV is only written when something changes (a stream
// starts or ends, or Relay sends a new list), and never listed.

const TWITCH_CLIENT_ID = 'kimne78kx3ncx6brgo4mv6wki5h1ko';
const MAX_CHANNELS = 300;
const MAX_TOPICS = 10;
const KICK_PER_RUN = 35;
// A stream that drops and comes back within this time doesn't alert again.
const RECONNECT_GRACE_MS = 10 * 60 * 1000;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const parts = url.pathname.split('/').filter(Boolean);
    const cors = { 'Access-Control-Allow-Origin': '*' };
    try {
      if (parts.length === 0) {
        return new Response('Relay live alerts is running.', { headers: cors });
      }
      const [route, topic] = parts;
      if (!topic || !/^[A-Za-z0-9_-]{12,64}$/.test(topic)) {
        return json({ error: 'bad topic' }, 400);
      }
      if (route === 'config' && request.method === 'PUT') {
        const body = await request.json();
        const channels = (Array.isArray(body.channels) ? body.channels : [])
          .filter((c) => c && (c.p === 'twitch' || c.p === 'kick') && typeof c.l === 'string')
          .map((c) => ({ p: c.p, l: c.l.toLowerCase().slice(0, 64) }))
          .slice(0, MAX_CHANNELS);
        const topics = (await env.ALERTS.get('topics', 'json')) || [];
        if (!topics.includes(topic)) {
          if (topics.length >= MAX_TOPICS) return json({ error: 'too many topics' }, 429);
          topics.push(topic);
          await env.ALERTS.put('topics', JSON.stringify(topics));
        }
        await env.ALERTS.put('cfg:' + topic, JSON.stringify({ channels }));
        return json({ ok: true, channels: channels.length });
      }
      if (route === 'config' && request.method === 'GET') {
        return json((await env.ALERTS.get('cfg:' + topic, 'json')) || { channels: [] });
      }
      if (route === 'test' && request.method === 'POST') {
        await notify(env, topic, {
          title: 'Relay live alerts work',
          message: "You'll get a notification like this when a streamer goes live.",
        });
        return json({ ok: true });
      }
      if (route === 'check' && request.method === 'POST') {
        // Run a check right now (handy for testing).
        const sent = await checkTopic(env, topic);
        return json({ ok: true, sent });
      }
      return json({ error: 'not found' }, 404);
    } catch (e) {
      return json({ error: String((e && e.message) || e) }, 500);
    }
  },

  async scheduled(event, env, ctx) {
    const topics = (await env.ALERTS.get('topics', 'json')) || [];
    for (const topic of topics) {
      try {
        await checkTopic(env, topic);
      } catch (e) {
        console.log('check failed for a topic: ' + e);
      }
    }
  },
};

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' },
  });
}

async function checkTopic(env, topic) {
  const cfg = (await env.ALERTS.get('cfg:' + topic, 'json')) || { channels: [] };
  if (!cfg.channels.length) return 0;
  const before = (await env.ALERTS.get('state:' + topic, 'json')) || {};

  const twitch = cfg.channels.filter((c) => c.p === 'twitch').map((c) => c.l);
  const kick = cfg.channels.filter((c) => c.p === 'kick').map((c) => c.l);
  const live = new Map(); // key -> { name, title, category, avatar, id }
  const checked = new Set(); // keys we got an answer for
  await Promise.all([
    twitchLive(twitch, live, checked).catch((e) => console.log('twitch: ' + e)),
    kickLive(env, kick, live, checked).catch((e) => console.log('kick: ' + e)),
  ]);

  const now = Date.now();
  const after = {};
  let changed = false;
  let sent = 0;
  for (const c of cfg.channels) {
    const key = c.p + ':' + c.l;
    const prev = before[key];
    if (!checked.has(key)) {
      // No answer this time: keep what we knew.
      if (prev) after[key] = prev;
      continue;
    }
    const s = live.get(key);
    if (s) {
      const wasLive = prev && prev.live;
      const recentlyOff = prev && !prev.live && prev.off && now - prev.off < RECONNECT_GRACE_MS;
      after[key] = { live: true };
      if (!wasLive) {
        changed = true;
        // Streamers just added (no earlier state) don't alert until they
        // next go live.
        if (prev && !recentlyOff) {
          await notify(env, topic, {
            title: `${s.name} is live`,
            message: [s.title, s.category].filter(Boolean).join(' · ') || 'Live now',
            click: `relay://open/${c.p}/${encodeURIComponent(c.l)}`,
            icon: s.avatar,
            tags: [c.p === 'kick' ? 'green_circle' : 'purple_circle'],
          });
          sent++;
        }
      }
    } else {
      if (prev && prev.live) {
        after[key] = { live: false, off: now };
        changed = true;
      } else if (prev) {
        after[key] = prev;
      } else {
        after[key] = { live: false };
        changed = true;
      }
    }
  }
  if (Object.keys(after).length !== Object.keys(before).length) changed = true;
  if (changed) await env.ALERTS.put('state:' + topic, JSON.stringify(after));
  return sent;
}

async function twitchLive(logins, live, checked) {
  for (let i = 0; i < logins.length; i += 100) {
    const chunk = logins.slice(i, i + 100);
    const res = await fetch('https://gql.twitch.tv/gql', {
      method: 'POST',
      headers: { 'Client-ID': TWITCH_CLIENT_ID, 'Content-Type': 'text/plain;charset=UTF-8' },
      body: JSON.stringify({
        query:
          'query($l:[String!]){users(logins:$l){login displayName profileImageURL(width:150) ' +
          'stream{id title game{displayName}}}}',
        variables: { l: chunk },
      }),
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const j = await res.json();
    const users = (j && j.data && j.data.users) || [];
    // Names Twitch didn't return (renamed/banned) count as offline.
    for (const l of chunk) checked.add('twitch:' + l);
    for (const u of users) {
      if (!u || !u.stream) continue;
      live.set('twitch:' + u.login.toLowerCase(), {
        name: u.displayName || u.login,
        title: u.stream.title,
        category: u.stream.game && u.stream.game.displayName,
        avatar: u.profileImageURL,
      });
    }
  }
}

let kickToken = null; // { token, until }

async function kickAppToken(env) {
  if (!env.KICK_CLIENT_ID || !env.KICK_CLIENT_SECRET) return null;
  if (kickToken && kickToken.until > Date.now()) return kickToken.token;
  const res = await fetch('https://id.kick.com/oauth/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'client_credentials',
      client_id: env.KICK_CLIENT_ID,
      client_secret: env.KICK_CLIENT_SECRET,
    }),
  });
  if (!res.ok) throw new Error('Kick token HTTP ' + res.status);
  const j = await res.json();
  kickToken = { token: j.access_token, until: Date.now() + ((j.expires_in || 3600) - 300) * 1000 };
  return kickToken.token;
}

async function kickLive(env, slugs, live, checked) {
  if (!slugs.length) return;
  const token = await kickAppToken(env);
  if (token) {
    // Kick's official API (needs a Kick developer app).
    for (let i = 0; i < slugs.length; i += 50) {
      const chunk = slugs.slice(i, i + 50);
      const q = chunk.map((s) => 'slug=' + encodeURIComponent(s)).join('&');
      const res = await fetch('https://api.kick.com/public/v1/channels?' + q, {
        headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' },
      });
      if (!res.ok) throw new Error('Kick API HTTP ' + res.status);
      const j = await res.json();
      for (const s of chunk) checked.add('kick:' + s);
      for (const ch of j.data || []) {
        if (!ch || !ch.stream || !ch.stream.is_live) continue;
        const slug = String(ch.slug || '').toLowerCase();
        live.set('kick:' + slug, {
          name: ch.slug,
          title: ch.stream_title,
          category: ch.category && ch.category.name,
          avatar: ch.banner_picture || undefined,
        });
      }
    }
    return;
  }
  // kick.com's own site API (no setup, but Kick's bot protection may refuse).
  // One request per channel, and Cloudflare's free plan allows ~50 requests
  // per run, so with many Kick channels a different batch is checked each
  // minute.
  let batch = slugs;
  if (slugs.length > KICK_PER_RUN) {
    const start = (Math.floor(Date.now() / 60000) * KICK_PER_RUN) % slugs.length;
    batch = [...slugs, ...slugs].slice(start, start + KICK_PER_RUN);
  }
  await Promise.all(
    batch.map(async (slug) => {
      const res = await fetch('https://kick.com/api/v2/channels/' + encodeURIComponent(slug), {
        headers: {
          Accept: 'application/json',
          'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15',
        },
      });
      if (!res.ok) return;
      let j;
      try {
        j = await res.json();
      } catch (e) {
        return; // got a bot-check page instead
      }
      checked.add('kick:' + slug);
      const ls = j && j.livestream;
      if (!ls || ls.is_live === false) return;
      live.set('kick:' + slug, {
        name: (j.user && j.user.username) || slug,
        title: ls.session_title,
        category: ls.categories && ls.categories[0] && ls.categories[0].name,
        avatar: j.user && j.user.profile_pic,
      });
    }),
  );
}

async function notify(env, topic, n) {
  const server = (env.NTFY_SERVER || 'https://ntfy.sh').replace(/\/+$/, '');
  const res = await fetch(server, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ topic, ...n }),
  });
  if (!res.ok) throw new Error('ntfy HTTP ' + res.status);
}
