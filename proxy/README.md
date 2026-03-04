# Sleepulator Feed Proxy

This Cloudflare Worker proxies private podcast feeds for the static Sleepulator app.

It is intentionally locked down:
- Requests must come from an allowed browser origin.
- Feed hosts must match `ALLOWED_FEED_HOSTS`.
- Only `http` and `https` feed URLs are allowed.

## Configure

Edit [wrangler.toml](/Users/melpools/Documents/_SITES/SLEEPULATOR/proxy/wrangler.toml):

- Set `name` to your Worker name.
- Set `ALLOWED_ORIGINS` to the site origins that should call the proxy.
  - For GitHub Pages, the origin is `https://blurbleasd.github.io`
  - For a custom domain, use that domain origin instead.
- Set `ALLOWED_FEED_HOSTS` to the feed hostnames you want to allow.
  - Example: `feeds.megaphone.fm,private.example.com,*.memberfulcontent.com`

## Deploy

```bash
cd /Users/melpools/Documents/_SITES/SLEEPULATOR/proxy
npx wrangler login
npx wrangler deploy
```

After deploy, copy the Worker URL and paste it into the app's `Private Feed Proxy` field, or set `feedProxyUrl` in [config.js](/Users/melpools/Documents/_SITES/SLEEPULATOR/config.js).

## Request shape

The app sends:

```json
{
  "url": "https://private-feed.example.com/abc123",
  "authHeader": ""
}
```

The Worker returns the upstream body and content type directly, plus:

- `X-Sleepulator-Final-Url`
- `X-Sleepulator-Upstream-Status`
