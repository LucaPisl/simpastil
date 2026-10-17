# Docker Official Images multi-platform index digests, retrieved 2026-09-25:
# https://hub.docker.com/layers/library/node/22.23.2-alpine3.24/images
# https://hub.docker.com/layers/library/nginx/1.31.5-alpine3.24/images
ARG NODE_IMAGE=docker.io/library/node:22.23.2-alpine3.24@sha256:b6f26b36c8ff49624cfdac716b8ea1138d606df02586a77d364bb5536a634f85
ARG NGINX_IMAGE=docker.io/library/nginx:1.31.5-alpine3.24@sha256:34f40471dea485273c5e2a04dd5e97a682332ceb4a9adecd67de450dcb2fb390

FROM ${NODE_IMAGE} AS admin-builder

WORKDIR /build/server/admin
COPY server/admin/package.json ./package.json
COPY server/admin/package-lock.json ./package-lock.json
RUN npm ci
COPY server/admin/index.html ./index.html
COPY server/admin/vite.config.ts ./vite.config.ts
COPY server/admin/tsconfig.json ./tsconfig.json
COPY server/admin/src/ ./src/
RUN npm run build

FROM ${NGINX_IMAGE} AS production
COPY nginx/nginx.conf /etc/nginx/nginx.conf
# The stock default site would also listen on port 80; only our templates remain.
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/templates/ /etc/nginx/templates/
# Port in the port-80 redirect; Compose sets it from NGINX_PUBLIC_HTTPS_PORT.
ENV NGINX_PUBLIC_HTTPS_PORT=34857
COPY --from=admin-builder /build/server/public/ /usr/share/nginx/html/
LABEL org.opencontainers.image.base.name="nginx:1.31.5-alpine3.24" \
      org.opencontainers.image.base.digest="sha256:34f40471dea485273c5e2a04dd5e97a682332ceb4a9adecd67de450dcb2fb390"

EXPOSE 80 34857
