#!/usr/bin/env bash

set -Eeuo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_ROOT="$(cd -- "${TEST_DIR}/../.." && pwd -P)"

bash -n "${STACK_ROOT}/scripts/setup-code-server.sh"
bash -n "${STACK_ROOT}/scripts/start-code-server.sh"
python3 -m json.tool "${TEST_DIR}/settings.json" >/dev/null

grep -Fq 'CODE_SERVER_PRIVATE_DIR:-/var/lib/ai-phone-stack/code-server' \
  "${STACK_ROOT}/scripts/start-code-server.sh"
grep -Fq 'CODE_SERVER_PASSWORD_FILE' \
  "${STACK_ROOT}/scripts/start-code-server.sh"
grep -Fq -- '--disable-proxy' "${STACK_ROOT}/scripts/start-code-server.sh"
grep -Fq 'exec env -i' "${STACK_ROOT}/scripts/start-code-server.sh"
grep -Fq 'extensions.autoUpdate": false' "${TEST_DIR}/settings.json"
grep -Fq 'http://127.0.0.1:8000/v1' "${TEST_DIR}/CLINE_SETUP.md"
grep -Fq 'llm/context-size.sh' "${TEST_DIR}/CLINE_SETUP.md"

if grep -Eq '^export PASSWORD=' "${STACK_ROOT}/scripts/start-code-server.sh"; then
  printf 'start-code-server.sh must not export PASSWORD to extension hosts\n' >&2
  exit 1
fi

printf 'code-server/Cline static checks: ok\n'
