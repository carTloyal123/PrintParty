# ── Build stage ────────────────────────────────────────────────────
FROM swift:6.3.2-jammy AS build

WORKDIR /build
COPY Package.swift Package.resolved* ./
COPY Sources/ Sources/
COPY Tests/ Tests/

# Resolve dependencies first (cacheable layer)
RUN swift package resolve

# Build DEBUG binary to get readable crash messages instead of SIGILL.
# Release mode uses ud2 for assertions/preconditions which shows as SIGILL.
RUN swift build -c debug \
    -Xlinker -lstdc++

# ── Runtime stage — use Swift image for debug runtime support ─────
FROM swift:6.3.2-jammy

RUN apt-get update && apt-get install -y --no-install-recommends \
    libcurl4 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home printparty \
    && mkdir -p /data \
    && chown printparty:printparty /data
USER printparty

COPY --from=build /build/.build/debug/printparty-gateway /usr/local/bin/printparty-gateway

ENV PRINTPARTY_DATA_DIR=/data
ENV SWIFT_BACKTRACE=enable=yes,demangle=yes
EXPOSE 8080

ENTRYPOINT ["printparty-gateway"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "8080"]
