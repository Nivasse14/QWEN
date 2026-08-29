#!/usr/bin/env bash

set -Eeuo pipefail
curl -fsS "http://127.0.0.1:${OPENWEBUI_PORT:-3000}/health"
printf '\n'
