FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends unbound dns-root-data ca-certificates \
 && rm -rf /var/lib/apt/lists/*
COPY unbound.conf /etc/unbound/unbound.conf
EXPOSE 53/tcp 53/udp
CMD ["unbound", "-d", "-c", "/etc/unbound/unbound.conf"]
