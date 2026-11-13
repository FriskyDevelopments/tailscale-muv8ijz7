# Pin base image to debian:bookworm-slim for reproducibility and smaller attack surface.
# Digest pinned 2026-10-07 – bump when pulling a newer stable release.
FROM debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
WORKDIR /render

ARG TAILSCALE_VERSION
ENV TAILSCALE_VERSION=${TAILSCALE_VERSION:-1.96.4}

RUN apt-get -qq update \
  && apt-get -qq install --upgrade -y --no-install-recommends \
    ca-certificates \
    curl \
    dnsutils \
    netcat-openbsd \
    wget \
  > /dev/null \
  && apt-get -qq clean \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

RUN echo "+search +short" > /root/.digrc

COPY install-tailscale.sh /tmp/install-tailscale.sh
RUN chmod +x /tmp/install-tailscale.sh && /tmp/install-tailscale.sh && rm -rf /tmp/*

COPY run-tailscale.sh /render/run-tailscale.sh
RUN chmod +x /render/run-tailscale.sh

CMD ["/render/run-tailscale.sh"]
