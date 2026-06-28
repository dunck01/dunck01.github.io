#!/bin/sh
set -e

# PostgreSQL archive_command wrapper
# If WAL-G S3 storage is configured, push to remote.
# Otherwise, keep WAL locally for later manual archive.

WAL_FILE="$1"

if [ -n "$WALG_S3_PREFIX" ] || [ -n "$WALG_FILE_PREFIX" ]; then
    wal-g wal-push "$WAL_FILE"
else
    test ! -f /var/lib/postgresql/wal_archive/$(basename "$WAL_FILE") && cp "$WAL_FILE" /var/lib/postgresql/wal_archive/
fi
