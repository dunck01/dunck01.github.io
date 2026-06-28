ARG POSTGRES_MAJOR=17
FROM postgres:${POSTGRES_MAJOR}-alpine

# Install curl, ca-certificates, and gcompat (glibc compatibility for Ubuntu WAL-G binary on Alpine)
RUN apk add --no-cache ca-certificates curl gcompat

# Download WAL-G v3.0.5
ARG WALG_VERSION=3.0.5
RUN curl -fsSL -o /usr/local/bin/wal-g \
    "https://github.com/wal-g/wal-g/releases/download/v${WALG_VERSION}/wal-g-pg-ubuntu-20.04-amd64" \
    && chmod +x /usr/local/bin/wal-g \
    && wal-g --version

# Copy wrapper script for archive_command fallback
COPY wal-push-wrapper.sh /usr/local/bin/wal-push-wrapper.sh
RUN chmod +x /usr/local/bin/wal-push-wrapper.sh

# Ensure local WAL archive dir exists (fallback path)
RUN mkdir -p /var/lib/postgresql/wal_archive
