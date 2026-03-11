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

## Local run

Requires `ffmpeg` installed on the machine:

```bash
cd audio-proxy
npm start
```

## Deploy

The easiest path is a Docker-based web service.

For Render:
1. Create a new Web Service from this repo.
2. Set the root directory to `audio-proxy`.
3. Render will use the included `Dockerfile`.
4. Set:
   - `ALLOWED_ORIGINS`
   - `ALLOWED_AUDIO_HOSTS`
5. Paste the deployed service URL into the app's `Sleep Safe proxy URL` field.

## Notes

- This is a streaming transcode, so seek/scrub behavior may be less precise than direct playback.
- Source hosts must be allowlisted to avoid turning the service into an open proxy.
- If your feed host serves episode audio from a separate CDN, add that CDN hostname to `ALLOWED_AUDIO_HOSTS`.
