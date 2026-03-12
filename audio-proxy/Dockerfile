FROM node:22-bookworm-slim

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=7860

WORKDIR /app

COPY package.json ./package.json
RUN npm install --omit=dev --no-audit --no-fund

COPY src ./src

EXPOSE 7860

CMD ["npm", "start"]
