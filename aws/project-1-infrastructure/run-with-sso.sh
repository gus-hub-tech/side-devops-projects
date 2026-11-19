#!/usr/bin/env bash
set -euo pipefail

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "Missing temporary AWS credentials. See README.md ('AWS access on the projects server')." >&2
  exit 1
fi

exec terraform "$@"
