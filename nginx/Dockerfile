# Docker Official Images multi-platform index digest, retrieved 2026-09-25:
# https://hub.docker.com/layers/library/nginx/1.31.7-alpine3.24/images
ARG NGINX_IMAGE=docker.io/library/nginx:1.31.7-alpine3.24@sha256:892bb2152464f0c5d8972593a5f5afaf8054552580b699d95f8ff4af08c2d33d

FROM ${NGINX_IMAGE} AS production
COPY nginx/nginx.conf /etc/nginx/nginx.conf
# The stock default site would also listen on port 80; only our templates remain.
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx/templates/ /etc/nginx/templates/
# Port in the port-80 redirect; Compose sets it from NGINX_PUBLIC_HTTPS_PORT.
ENV NGINX_PUBLIC_HTTPS_PORT=34857
LABEL org.opencontainers.image.base.name="nginx:1.31.7-alpine3.24" \
      org.opencontainers.image.base.digest="sha256:892bb2152464f0c5d8972593a5f5afaf8054552580b699d95f8ff4af08c2d33d"

EXPOSE 80 34857
