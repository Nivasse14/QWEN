#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
STACK_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REPOSITORY_PATH="${1:-/workspace/repos/Nivasse14/QWEN}"
DEPLOY_KEY_PATH="${GITHUB_DEPLOY_KEY_PATH:-/root/.ssh/ai-phone-qwen-deploy}"
KNOWN_HOSTS_SOURCE="${STACK_ROOT}/config/github/known_hosts"
KNOWN_HOSTS_PATH="${GITHUB_KNOWN_HOSTS_PATH:-/root/.ssh/github_known_hosts}"
SSH_COMMAND="ssh -i ${DEPLOY_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${KNOWN_HOSTS_PATH}"

die() { printf '[github-deploy-key] ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "root requis"
[[ -d "${REPOSITORY_PATH}/.git" ]] || die "dépôt Git introuvable: ${REPOSITORY_PATH}"
[[ -f "${DEPLOY_KEY_PATH}" && ! -L "${DEPLOY_KEY_PATH}" ]] || \
  die "clé privée absente ou non sûre: ${DEPLOY_KEY_PATH}"
[[ -f "${KNOWN_HOSTS_SOURCE}" && ! -L "${KNOWN_HOSTS_SOURCE}" ]] || \
  die "known_hosts officiel absent"

install -d -m 0700 /root/.ssh
chmod 0600 "${DEPLOY_KEY_PATH}"
ssh-keygen -y -f "${DEPLOY_KEY_PATH}" >/dev/null || die "clé privée invalide"
install -m 0600 "${KNOWN_HOSTS_SOURCE}" "${KNOWN_HOSTS_PATH}"

git -C "${REPOSITORY_PATH}" remote set-url origin git@github.com:Nivasse14/QWEN.git
git -C "${REPOSITORY_PATH}" config core.sshCommand "${SSH_COMMAND}"

printf '[github-deploy-key] origin SSH configuré pour Nivasse14/QWEN\n'
