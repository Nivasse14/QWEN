# Tools API

Restricted FastAPI/OpenAPI bridge for Open WebUI. It exposes fixed GitHub,
repository-file, server-diagnostic and FLUX orchestration operations; it never
accepts a raw command or a caller-selected executable.

## Runtime configuration

All credentials are environment variables. Do not write them below
`/workspace`, bake them into an image, or put them in a Compose file.

Required variables:

- `TOOLS_API_BEARER_TOKEN`: random internal token, at least 24 characters.
- `GITHUB_TOKEN` (or `GITHUB_PAT`): fine-grained token used only as `GH_TOKEN`.
- `GITHUB_ALLOWED_REPOS`: comma-separated `owner/repository` allowlist. Empty
  means no repository is authorized.
- `FLUX_ORCHESTRATOR_TOKEN`: bearer token for the private GPU orchestrator.

Optional variables:

- `REPOS_ROOT` (default `/workspace/repos`)
- `FLUX_ORCHESTRATOR_URL`
- `COMMAND_TIMEOUT_SECONDS`, `GIT_TIMEOUT_SECONDS`, `FLUX_TIMEOUT_SECONDS`
- `MAX_COMMAND_OUTPUT_BYTES`, `MAX_TEXT_FILE_BYTES`, `MAX_CAT_BYTES`
- `MAX_FLUX_RESPONSE_BYTES`, `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`

Run from this directory with `uvicorn tools_api.asgi:app --host 127.0.0.1
--port 8002`, or use the native `setup.sh` and `start.sh` scripts. Configure
Open WebUI's global tool-server connection with
`http://127.0.0.1:8002/openapi.json` and the same internal bearer token.
`/healthz` is the only unauthenticated route.

The container needs `git` and `gh`. It does not need, and must not receive, the
Docker socket. `docker_ps` works only if a separately constrained environment
already provides both the Docker CLI and daemon access.

## Local tests

Install `requirements-dev.txt`, then run `pytest -q`. Tests use dummy injected
tokens and temporary directories; they do not read network credentials or call
GitHub, Docker, or the FLUX service.
