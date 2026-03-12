# SLEEPULATOR — Phone Install Guide

## What changed

Your app is now a proper **Progressive Web App (PWA)** with:
- ✅ Background audio that keeps playing when your screen locks
- ✅ Lock screen controls (play/pause/skip) for both podcasts AND ambient noise
- ✅ Offline support — app shell cached by Service Worker
- ✅ 8 noise/soundscape types (brown, pink, green, white, fan, rain, ocean, forest)
- ✅ Safe-area padding for iPhone notch and home indicator
- ✅ No-zoom touch target sizing for comfortable phone use

---

## Files

```
SLEEPULATOR/
├── index.html      ← The app
├── config.js       ← Optional shared app config
├── manifest.json   ← PWA identity & icons
├── sw.js           ← Service Worker (offline + caching)
├── proxy/          ← Optional Cloudflare Worker for private feeds
└── audio-proxy/    ← Optional server for Sleep Safe podcast playback
```

The app shell files (`index.html`, `config.js`, `manifest.json`, `sw.js`) should stay in the same folder and be served from the same web server.

---

## Option A: Free hosting with GitHub Pages (Recommended)

1. Create a free account at [github.com](https://github.com)
2. Create a new **public** repository (e.g. `sleepulator`)
3. Upload the app shell files (`index.html`, `config.js`, `manifest.json`, `sw.js`)
4. Go to **Settings → Pages → Source → main branch → / (root) → Save**
5. Your URL will be: `https://yourusername.github.io/sleepulator/`
6. Open that URL in **Safari (iPhone)** or **Chrome (Android)**
7. Follow the install step below

---

## Option B: Free hosting with Netlify

1. Go to [netlify.com](https://netlify.com) → "Add new site → Deploy manually"
2. Drag the entire SLEEPULATOR folder onto the drop zone
3. You'll get a URL like `https://random-name.netlify.app`
4. Open it on your phone and install

---

## Option C: Local network (same Wi-Fi)

If you have Python installed on your Mac/PC:
```bash
cd /path/to/SLEEPULATOR
python3 -m http.server 8080
```
Then open `http://YOUR-COMPUTER-IP:8080` on your phone.
⚠️  Service Worker won't activate over plain HTTP (only localhost or HTTPS).

---

## Installing on your phone

### iPhone (Safari only — Chrome won't allow install on iOS)
1. Open the hosted URL in **Safari**
2. Tap the **Share** button (box with arrow)
3. Scroll down and tap **"Add to Home Screen"**
4. Tap **Add** — the 🌙 icon appears on your home screen
5. Launch from home screen — it opens fullscreen with no browser UI

### Android (Chrome)
1. Open the URL in **Chrome**
2. Tap the three-dot menu → **"Add to Home Screen"** or **"Install app"**
3. Tap Install

---

## Background audio & lock screen

Once installed and running:
- Audio plays continuously when you lock the screen
- The lock screen shows **Now Playing** controls (play/pause, skip for podcasts)
- Ambient noise and binaural beats show as "Ambient Noise" / "Binaural Beats" on the lock screen
- The **Still Awake? (+15 min)** button fires before the timer cuts audio

### iOS note
iOS requires the user to interact with the page before audio can start (Apple policy). Tap any Play button once while the screen is on — after that, audio continues in the background indefinitely.

---

## Private feeds

If a member-only feed still fails in the app, that is usually a browser fetch restriction rather than an XML parsing problem.

You now have two ways to configure the private proxy:
- Paste the deployed Worker URL into the app's `Private Feed Proxy` field.
- Set `feedProxyUrl` in `config.js` so every device uses the same proxy automatically.

To deploy the included proxy:

```bash
cd /Users/melpools/Documents/_SITES/SLEEPULATOR/proxy
npx wrangler login
npx wrangler deploy
```

Before deploy, edit `proxy/wrangler.toml` and set:
- `ALLOWED_ORIGINS`
- `ALLOWED_FEED_HOSTS`

---

## Sleep Safe podcast playback

If you want server-side loudness normalization and peak limiting for podcast audio:

1. Create a Render Blueprint from this repo so it picks up [render.yaml](/Users/melpools/Documents/_SITES/SLEEPULATOR/render.yaml)
2. Deploy the `sleepulator-audio-proxy` service from `audio-proxy/`
3. Set or adjust:
   - `ALLOWED_ORIGINS`
   - `ALLOWED_AUDIO_HOSTS`
4. Paste the deployed service URL into the app's `Sleep Safe proxy URL` field
5. Turn on `Sleep Safe Audio`

This mode keeps iPhone playback on a native media element, which is the background-safe path. The tradeoff is that seek/scrub can be less precise because the audio is transcoded as a live stream.

---

## Editing the app later

Edit the `<script type="text/babel">` section of `index.html`. The JSX is compiled in the browser by Babel, so no build step is needed.
