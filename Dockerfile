# postgres-backup-s3cmd
# PostgreSQL dump backups to S3-compatible storage using s3cmd
#
# Build args:
#   ALPINE_VERSION - Alpine Linux version (e.g., 3.21)
#   PG_MAJOR - PostgreSQL major version (e.g., 18)
#
# Example:
#   docker build --build-arg ALPINE_VERSION=3.21 --build-arg PG_MAJOR=18 -t postgres-backup-s3cmd:18 .

ARG ALPINE_VERSION=3.21

FROM alpine:${ALPINE_VERSION}

ARG TARGETARCH
ARG PG_MAJOR=18

# Build-time arguments for OCI labels (set by CI)
ARG BUILD_VERSION=dev
ARG BUILD_DATE
ARG VCS_REF

# OCI Image Labels
# https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="postgres-backup-s3cmd" \
      org.opencontainers.image.description="PostgreSQL dump backups to S3-compatible storage using s3cmd" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/StefanMarkmann/postgres-backup-s3cmd" \
      org.opencontainers.image.url="https://github.com/StefanMarkmann/postgres-backup-s3cmd" \
      org.opencontainers.image.documentation="https://github.com/StefanMarkmann/postgres-backup-s3cmd#readme" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="alpine:${ALPINE_VERSION}" \
      io.github.stefanmarkmann.pg_major="${PG_MAJOR}" \
      io.github.stefanmarkmann.alpine_version="${ALPINE_VERSION}"

# Install dependencies
COPY src/install.sh /install.sh
RUN PG_MAJOR=${PG_MAJOR} TARGETARCH=${TARGETARCH} sh /install.sh && rm /install.sh

# PostgreSQL connection
ENV POSTGRES_HOST=''
ENV POSTGRES_PORT=5432
ENV POSTGRES_USER=''
ENV POSTGRES_PASSWORD=''
ENV POSTGRES_DATABASE=''
ENV PGDUMP_EXTRA_OPTS=''

# S3 configuration
ENV S3_ACCESS_KEY_ID=''
ENV S3_SECRET_ACCESS_KEY=''
ENV S3_BUCKET=''
ENV S3_REGION='us-east-1'
ENV S3_PREFIX='backup'
ENV S3_ENDPOINT=''

# Backup configuration
ENV SCHEDULE=''
ENV PASSPHRASE=''
ENV BACKUP_KEEP_DAYS=''
ENV COMPRESSION='zstd'
ENV ZSTD_LEVEL=3
ENV ZSTD_CHECKSUM=true

# Write version file for runtime banner
RUN echo "${BUILD_VERSION}" > /VERSION

# Copy scripts
COPY src/common.sh /common.sh
COPY src/env.sh /env.sh
COPY src/run.sh /run.sh
COPY src/backup.sh /backup.sh
COPY src/restore.sh /restore.sh
COPY src/list.sh /list.sh
COPY src/cleanup.sh /cleanup.sh
COPY src/delete.sh /delete.sh

# Set working directory
WORKDIR /

CMD ["sh", "/run.sh"]
