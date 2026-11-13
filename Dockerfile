FROM debian:bookworm-slim

WORKDIR /render

ARG TAILSCALE_VERSION=1.96.4
ENV TAILSCALE_VERSION=${TAILSCALE_VERSION}

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    python3 \
    wget \
  && rm -rf /var/lib/apt/lists/*

COPY install-tailscale.sh /tmp/install-tailscale.sh
RUN chmod +x /tmp/install-tailscale.sh \
  && /tmp/install-tailscale.sh \
  && rm -f /tmp/install-tailscale.sh

COPY run-tailscale.sh /render/run-tailscale.sh
RUN chmod +x /render/run-tailscale.sh

CMD ["/render/run-tailscale.sh"]
