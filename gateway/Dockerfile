# ── Build stage ────────────────────────────────────────────────────
FROM swift:6.3.2-jammy AS build

WORKDIR /build

# Copy shared PrintPartyKit package first (referenced as ../PrintPartyKit
# in Package.swift — the Docker build context is the repo root).
COPY PrintPartyKit/ PrintPartyKit/

# Copy gateway package manifest and sources.
COPY gateway/Package.swift gateway/Package.resolved* gateway/
COPY gateway/Sources/ gateway/Sources/
COPY gateway/Tests/ gateway/Tests/

WORKDIR /build/gateway

# Resolve dependencies first (cacheable layer)
RUN swift package resolve

# Build release binary with static Swift stdlib
RUN swift build -c release --static-swift-stdlib \
    -Xlinker -lstdc++

# ── Runtime stage (~30MB slim + libcurl for URLSession on Linux) ──
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home printparty \
    && mkdir -p /data \
    && chown printparty:printparty /data
USER printparty

COPY --from=build /build/gateway/.build/release/printparty-gateway /usr/local/bin/printparty-gateway

ENV PRINTPARTY_DATA_DIR=/data
EXPOSE 8080

ENTRYPOINT ["printparty-gateway"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
