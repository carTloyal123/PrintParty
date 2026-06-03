# ── Build stage ────────────────────────────────────────────────────
FROM swift:6.3.2-jammy AS build

WORKDIR /build
COPY Package.swift Package.resolved* ./
COPY Sources/ Sources/

# Resolve dependencies first (cacheable layer)
RUN swift package resolve

# Build release binary with static Swift stdlib
RUN swift build -c release --static-swift-stdlib \
    -Xlinker -lstdc++

# ── Runtime stage (~30MB slim) ────────────────────────────────────
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home printparty
USER printparty

COPY --from=build /build/.build/release/printparty-relay /usr/local/bin/printparty-relay

EXPOSE 8090

# Mount .p8 key at runtime:
#   docker run -v /path/to/AuthKey.p8:/home/printparty/AuthKey.p8:ro \
#     -e APNS_KEY_PATH=/home/printparty/AuthKey.p8 \
#     -e APNS_KEY_ID=... -e APNS_TEAM_ID=... printparty-relay

ENTRYPOINT ["printparty-relay"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8090"]
