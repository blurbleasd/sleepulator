FROM node:24-bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid 1000 appuser

WORKDIR /home/appuser/app

COPY --chown=appuser:appuser package.json ./
COPY --chown=appuser:appuser src ./src

ENV NODE_ENV=production
ENV HOST=0.0.0.0
ENV PORT=7860

USER appuser

EXPOSE 7860

CMD ["node", "src/server.js"]
