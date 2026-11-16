#!/usr/bin/env bash
# Checks that the schema is valid, then validates a catalog file against it.
# Usage: bash catalog/validate.sh [path/to/catalog.json]
# The path defaults to catalog/catalog.json. Exits 0 on success and non-zero on any failure.
set -euo pipefail

AJV_CLI_VERSION="5.0.0"

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
schema="$dir/catalog.schema.json"
data="${1:-$dir/catalog.json}"

if ! command -v npx >/dev/null 2>&1; then
  echo "validate.sh needs node and npx on your PATH." >&2
  exit 2
fi
if [ ! -f "$data" ]; then
  echo "validate.sh cannot find $data." >&2
  exit 2
fi

ajv() {
  npx --yes "ajv-cli@$AJV_CLI_VERSION" "$@"
}

ajv compile --spec=draft7 -s "$schema"
ajv validate --spec=draft7 -s "$schema" -d "$data"
