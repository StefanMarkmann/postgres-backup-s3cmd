#!/bin/sh
# install.sh - Install dependencies for postgres-backup-s3cmd
#
# This script is run during Docker image build.
# It installs PostgreSQL client, s3cmd, GPG, and go-cron.

set -eu

apk update

# Install PostgreSQL client (version set by build arg PG_MAJOR)
apk add "postgresql${PG_MAJOR}-client"

# Install GPG for encryption
apk add gnupg

# Install s3cmd for S3-compatible storage
apk add s3cmd

# Install curl for downloading go-cron
apk add curl

# Install go-cron for scheduling
# https://github.com/ivoronin/go-cron
GO_CRON_VERSION="0.0.5"
curl -fsSL "https://github.com/ivoronin/go-cron/releases/download/v${GO_CRON_VERSION}/go-cron_${GO_CRON_VERSION}_linux_${TARGETARCH}.tar.gz" -o go-cron.tar.gz
tar xzf go-cron.tar.gz
rm go-cron.tar.gz
mv go-cron /usr/local/bin/go-cron
chmod +x /usr/local/bin/go-cron

# Remove curl (not needed at runtime)
apk del curl

# Cleanup
rm -rf /var/cache/apk/*
