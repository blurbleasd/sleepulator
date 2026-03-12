FROM node:22-bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && useradd -m -u 1000 user

USER user

ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH \
    NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=7860

WORKDIR $HOME/app

COPY --chown=user package.json ./package.json
COPY --chown=user src ./src

EXPOSE 7860

CMD ["npm", "start"]
