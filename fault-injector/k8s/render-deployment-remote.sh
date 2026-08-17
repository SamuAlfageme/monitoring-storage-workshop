#!/usr/bin/env bash
# Renders deployment-remote.yaml with image and optional imagePullSecrets.
set -euo pipefail

image="${1:?image ref required}"
secret_name="${2:-}"
tpl="$(dirname "$0")/deployment-remote.yaml"

content="$(sed "s|__FAULT_INJECTOR_IMAGE__|${image}|g" "$tpl")"

if [ -n "$secret_name" ]; then
  content="$(printf '%s\n' "$content" \
    | sed "s|__IMAGE_PULL_SECRET__|${secret_name}|g" \
    | sed '/__BEGIN_IMAGE_PULL_SECRETS__/d' \
    | sed '/__END_IMAGE_PULL_SECRETS__/d')"
else
  content="$(printf '%s\n' "$content" \
    | sed '/__BEGIN_IMAGE_PULL_SECRETS__/,/__END_IMAGE_PULL_SECRETS__/d')"
fi

printf '%s\n' "$content"
