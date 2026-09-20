# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Build context is ./app  ->  docker build -t canary-app:v1 ./app
# ---------------------------------------------------------------------------

FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

FROM node:22-alpine AS runtime
WORKDIR /app

ENV NODE_ENV=production \
    PORT=8080 \
    TRACK=stable \
    APP_VERSION=1.0.0

# Metadata is filled in by scripts/build-push.sh so every image is traceable.
ARG APP_VERSION=1.0.0
ARG GIT_SHA=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="ECS Canary in Action" \
      org.opencontainers.image.description="Traffic split monitor for ECS canary deployments" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_TIME}" \
      org.opencontainers.image.source="https://github.com/roxsross/aws-ecs-canary-in-action"

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src
COPY public ./public
COPY scripts ./scripts

# node:alpine already ships an unprivileged `node` user (uid 1000).
USER node

EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=4s --start-period=8s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
