# ── Build stage ────────────────────────────────────────────────────
FROM swift:6.3.2-jammy AS build

WORKDIR /build
COPY Package.swift Package.resolved* ./
COPY Sources/ Sources/
COPY Tests/ Tests/

# Resolve dependencies first (cacheable layer)
RUN swift package resolve

# Build release binary with static Swift stdlib.
# -march=x86-64: target baseline x86-64 ISA to avoid SIGILL on older CPUs
# (e.g. Ivy Bridge) that lack AVX2/BMI2.
RUN swift build -c release --static-swift-stdlib \
    -Xcc -march=x86-64 \
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

COPY --from=build /build/.build/release/printparty-gateway /usr/local/bin/printparty-gateway

ENV PRINTPARTY_DATA_DIR=/data
EXPOSE 8080

ENTRYPOINT ["printparty-gateway"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
