# Docker Official Images multi-platform index, retrieved 2026-09-25:
# https://hub.docker.com/layers/library/node/24.22.0-alpine3.24/images
ARG NODE_IMAGE=docker.io/library/node:24.22.0-alpine3.24@sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f

# ─── Stage 1: API builder ─────────────────────────────────────────────────────
FROM ${NODE_IMAGE} AS builder

WORKDIR /app

# Copy dependency manifests first so Docker can cache this layer separately.
COPY package*.json ./
RUN npm ci

# Copy all source files needed for compilation.
COPY tsconfig.json ./
COPY drizzle.config.ts ./
COPY src/ ./src/

# Compile TypeScript → dist/
RUN npm run build

# ─── Stage 2: Shared runtime image ────────────────────────────────────────────
FROM ${NODE_IMAGE} AS runtime

# The base image ships a 'node' user at UID 1000. Re-create at UID 1001
# to match the specified security baseline.
RUN deluser --remove-home node 2>/dev/null || true \
    && delgroup node 2>/dev/null || true \
    && addgroup -S -g 1001 nodejs \
    && adduser  -S -u 1001 -G nodejs node

WORKDIR /app

# Install production dependencies only — no devDependencies in the image.
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# Copy compiled JS output from the builder stage.
COPY --from=builder /app/dist ./dist

# Copy Drizzle migration files (SQL + meta/_journal.json).
# tsc does not copy non-.ts files, so we pull them straight from the source tree.
COPY --from=builder /app/src/db/migrations ./dist/db/migrations/

# Hand ownership of the working directory to the non-root user.
RUN chown -R node:nodejs /app

# /tmp must remain writable (Node.js runtime scratch space).
# docker-compose pairs this with a tmpfs mount when read_only: true is set.
VOLUME ["/tmp"]

USER node

EXPOSE 8080

# Liveness uses the explicit versioned API endpoint; bare / intentionally 404s.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "\
const h = require('node:http'); \
h.get( \
  { host: '127.0.0.1', port: Number(process.env['PORT'] ?? 3000), path: '/api/v1/health/live' }, \
  r => process.exit(r.statusCode < 500 ? 0 : 1) \
).on('error', () => process.exit(1))"

CMD ["node", "dist/index.js"]

# The two build profiles use the same compiled output. Compatibility relaxes
# only the runtime minimum-client gate; ledger authority remains server-owned.
FROM runtime AS compatibility
ENV SIMPASTIL_BUILD_PROFILE=compatibility
LABEL org.opencontainers.image.base.name="node:24.22.0-alpine3.24" \
      org.opencontainers.image.base.digest="sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f" \
      io.simpastil.build-profile="compatibility" \
      io.simpastil.compatible-schema-range="0025..0025"

FROM runtime AS production
ENV SIMPASTIL_BUILD_PROFILE=production
LABEL org.opencontainers.image.base.name="node:24.22.0-alpine3.24" \
      org.opencontainers.image.base.digest="sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f" \
      io.simpastil.build-profile="production" \
      io.simpastil.compatible-schema-range="0025..0025"

# The automatic pre-migration backup runs the production code plus the
# PostgreSQL 16 client (pg_dump/psql). Kept as its own image so the API and
# worker images do not carry database dump tooling.
FROM production AS backup
USER root
RUN apk add --no-cache postgresql16-client
USER node
LABEL io.simpastil.build-profile="backup"
CMD ["node", "dist/commands/premigrate-backup.js"]
