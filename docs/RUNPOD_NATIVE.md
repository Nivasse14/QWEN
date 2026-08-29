# Exécution native sur un RunPod Pod

Ce dossier cible un **seul conteneur de template RunPod**. Il ne lance pas
Docker à l'intérieur du Pod : RunPod Pods ne fournit pas de démon Docker ni de
Docker-in-Docker pris en charge. `docker-compose.yml` est seulement une
référence pour une machine Linux classique ; son profil explicite empêche un
démarrage accidentel par `docker compose up`.

## Stockage persistant et permissions

Placer ce dépôt dans `/workspace/ai-phone-stack`. Les binaires téléchargés,
extensions, états et identités sont créés dans `.runtime/`, `vendor/` et
`state/`, donc sur le volume persistant.

Le volume réseau RunPod est monté via FUSE et peut forcer les répertoires en
`0777` et les fichiers en `0666`. Il ne faut **jamais y écrire de clé API, de
PAT, de clé Tailscale ni de mot de passe**. Injecter ces valeurs comme variables
secrètes depuis le template RunPod ou le processus de lancement. Les options
`*_SECRET_FILE` ne fonctionnent volontairement qu'avec un fichier réellement
privé (`0600`, par exemple sur le disque conteneur temporaire).

L'état d'identité de Tailscale contient lui-même des credentials. Le script le
place donc par défaut dans `/var/lib/ai-phone-stack/tailscale`, sur le disque
conteneur privé, et vérifie ses permissions. Un terminate/redeploy perd cette
identité et le nouveau Pod s'authentifie avec la clé injectée. C'est le compromis
nécessaire pour ne pas écrire de credential sur le volume FUSE. Utiliser une clé
Tailscale réutilisable/éphémère gérée côté tailnet et supprimer les anciens
nœuds selon la politique d'administration.

## Installation (une fois)

Depuis `/workspace/ai-phone-stack` :

```bash
./scripts/setup-searxng.sh
./scripts/setup-code-server.sh
./scripts/setup-tailscale.sh
```

Le script code-server installe Cline (`saoudrizwan.claude-dev`). Si la galerie
de code-server ne le propose pas, fournir un VSIX vérifié à la volée :

```bash
CLINE_VSIX_PATH=/tmp/cline.vsix ./scripts/setup-code-server.sh
```

## Démarrage des processus

Le template doit utiliser un superviseur (s6, supervisord ou systemd) et lancer
au moins ces commandes en processus séparés :

```bash
SEARXNG_SECRET="variable-secrete-injectee" ./scripts/start-searxng.sh
CODE_SERVER_PASSWORD="variable-secrete-injectee" ./scripts/start-code-server.sh
TAILSCALE_AUTH_KEY="variable-secrete-injectee" ./scripts/start-tailscale.sh
```

Les services applicatifs écoutent uniquement sur `127.0.0.1`. Tailscale tourne
avec `--tun=userspace-networking`, puis `tailscale serve` publie dans le tailnet :

- `TAILNET_IP:3000` vers Open WebUI ;
- `TAILNET_IP:8443` vers code-server ;
- `TAILNET_IP:8188` vers ComfyUI.

SearXNG reste privé sur `127.0.0.1:8888`. Le publier temporairement nécessite
`TAILSCALE_SERVE_SEARXNG=1`. Le proxy SOCKS5 local est sur `127.0.0.1:1055` et
le proxy HTTP sortant sur `127.0.0.1:1056`.

RunPod Pods ne prend pas en charge l'UDP exposé. Tailscale peut donc relayer le
trafic via DERP/TCP, ce qui fonctionne mais ajoute parfois de la latence. Cette
configuration n'ouvre aucun port public et ne demande aucun port forwarding.

## Cline

Après le premier démarrage, suivre
[`config/code-server/CLINE_SETUP.md`](../config/code-server/CLINE_SETUP.md).
L'API vLLM attendue est `http://127.0.0.1:8000/v1`.

## Vérifications locales au Pod

```bash
curl -fsS 'http://127.0.0.1:8888/search?q=RunPod&format=json'
curl -fsS http://127.0.0.1:8000/v1/models
curl -I http://127.0.0.1:8443
./.runtime/tailscale/bin/tailscale --socket=/run/ai-phone-stack/tailscale/tailscaled.sock status
```
