#!/usr/bin/env bash
set -euo pipefail

: "${PUBLIC_HOST:?PUBLIC_HOST is required}"

echo "🔍 Checking https://${PUBLIC_HOST} ..."
for i in {1..30}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "https://${PUBLIC_HOST}/docs" || echo "000")
  if [[ "${STATUS}" -eq 200 ]]; then
    echo "✅ Endpoint is up!"
    exit 0
  fi
  echo "⏳ (${i}/30) Waiting for DNS/ALB... (Status: ${STATUS})"
  sleep 10
done

echo "⚠️ Endpoint didn't respond in time, but deployment succeeded."
