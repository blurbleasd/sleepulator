---
title: Sleepulator Audio Proxy
emoji: 🌙
colorFrom: blue
colorTo: indigo
sdk: docker
app_port: 7860
pinned: false
---

# Sleepulator Audio Proxy

This service adds an optional `Sleep Safe Audio` playback path for podcast episodes.

It fetches the source episode audio, runs it through `ffmpeg`, and streams back:
- light loudness normalization
- true-peak limiting

That keeps the iPhone app on a single native `<audio>` stream, which is the background-safe path.

## Endpoints

- `GET /health`
- `GET /audio?url=https://example.com/episode.mp3&profile=sleep-safe`

## Environment variables

- `PORT`
- `FFMPEG_BIN`
- `ALLOWED_ORIGINS`
- `ALLOWED_AUDIO_HOSTS`
- `TARGET_BITRATE`

The Docker Space build uses the bundled `@ffmpeg-installer/ffmpeg` package, so it does not depend on `apt-get` installing system packages during the image build.

## Local run

Requires `npm install` first. If you do not set `FFMPEG_BIN`, the app will try the bundled npm binary and then fall back to a system `ffmpeg` if one is installed:

```bash
cd audio-proxy
npm install
npm start
```

## Deploy to Hugging Face Spaces

This folder is set up to be the root of a Docker Space.

1. Create a new Space on Hugging Face.
2. Choose `Docker` as the SDK.
3. Upload the contents of this `audio-proxy/` folder as the Space repo.
4. In the Space settings, add variables for:
   - `ALLOWED_ORIGINS`
   - `ALLOWED_AUDIO_HOSTS`
   - `TARGET_BITRATE`
5. Wait for the Space build to finish.
6. Paste the deployed Space URL into the app's `Sleep Safe proxy URL` field.

Recommended variables for the current app:

```text
ALLOWED_ORIGINS=https://blurbleasd.github.io
ALLOWED_AUDIO_HOSTS=cbbworld.memberfulcontent.com,www.patreon.com
TARGET_BITRATE=96k
```

The Docker image listens on port `7860`, which matches the Space metadata above.
The app can use the plain Space URL and will target `/audio` automatically.

## Notes

- This is a streaming transcode, so seek/scrub behavior may be less precise than direct playback.
- Source hosts must be allowlisted to avoid turning the service into an open proxy.
- If your feed host serves episode audio from a separate CDN, add that CDN hostname to `ALLOWED_AUDIO_HOSTS`.
