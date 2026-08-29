# QWEN — pile IA mobile native sur RunPod

Ce dossier orchestre la pile du dépôt
[`Nivasse14/QWEN`](https://github.com/Nivasse14/QWEN) dans **un seul RunPod
Pod**, sans Docker-in-Docker et sans port public. Les processus écoutent sur
`127.0.0.1`; Tailscale userspace publie uniquement les interfaces destinées au
téléphone.

Le serveur de modèle actuellement intégré est `llama.cpp` avec une API
compatible OpenAI sur le port 8000. C'est le chemin natif retenu pour le GGUF
Q4_K_M sur une carte de 24 Go. ComfyUI ne partage pas la VRAM en permanence :
l'orchestrateur d'images arrête temporairement le LLM, génère l'image, libère
ComfyUI, puis restaure le LLM.

Déploiement vérifié le 29 août 2026 : Pod `ew6jja07rnn0cg`, région
`EU-RO-1`, volume réseau `n10j3zet9z` de 300 Go. Le Pod existant utilise une
RTX 5090 à 0,99 $/h : il fonctionne, mais ne respecte pas le budget cible.

## URLs depuis le téléphone

Après connexion du téléphone au même tailnet, `./status-stack.sh` affiche l'IP
et les liens exacts :

| Interface | URL Tailscale | Remarque |
|---|---|---|
| Open WebUI | `http://<TAILSCALE_IP>:3000` | Chat, web, Python, GitHub et images |
| code-server | `http://<TAILSCALE_IP>:8443` | VS Code mobile et Cline |
| ComfyUI | `http://<TAILSCALE_IP>:8188` | Actif uniquement pendant le mode image |

Services internes non publiés : LLM `127.0.0.1:8000`, FLUX API `:8003`, Tools
API `:8002` et SearXNG `:8889`. Le port `8888` reste réservé au Jupyter du Pod.

## Commandes de cycle de vie dans le Pod

```bash
cd /workspace/ai-phone-stack
sudo ./start-stack.sh
./status-stack.sh
sudo ./stop-stack.sh
```

`start-stack.sh` est idempotent, sérialise les opérations start/stop, vérifie
chaque endpoint et revient à l'état arrêté si une étape échoue. Il démarre :

1. secrets temporaires sous `/run` et SearXNG sur `8889` ;
2. LLM en mode GPU normal et orchestrateur FLUX ;
3. Tools API, Open WebUI et code-server ;
4. Tailscale, après que les services locaux sont sains.

`stop-stack.sh` retire d'abord l'accès Tailscale, puis arrête les consommateurs
et enfin les processus GPU. Il ne signale que les PID dont la ligne de commande
correspond au service attendu, afin d'éviter de tuer un processus réutilisant un
ancien numéro de PID.

## Secrets

Le volume réseau RunPod force typiquement les fichiers en `0666`. Aucun PAT,
token Hugging Face, clé Tailscale ou mot de passe ne doit être enregistré dans
`/workspace`, `.env` ou Git.

Le stockage source privé est `/root/.config/ai-phone-stack/secrets`, et les
copies d'exécution sont sous `/run/secrets/ai-phone-stack`. Saisir les valeurs
sans affichage :

```bash
cd /workspace/ai-phone-stack
sudo ./scripts/store-secret.sh github_token
sudo ./scripts/store-secret.sh hf_token
sudo ./scripts/store-secret.sh tailscale_auth_key
# Facultatif : protège aussi l'API LLM locale.
sudo ./scripts/store-secret.sh llama_api_key
```

Les secrets internes Open WebUI, Tools API, SearXNG, FLUX et code-server sont
générés par `scripts/bootstrap-secrets.sh`. Le démarrage exige les tokens
GitHub et Tailscale. Le périmètre GitHub par défaut est strictement
`Nivasse14/QWEN`; le modifier nécessite une valeur explicite de
`GITHUB_ALLOWED_REPOS`.

Le disque conteneur privé disparaît lors d'un terminate/redeploy. Il faut donc
réinjecter les secrets externes au nouveau Pod. L'identité Tailscale est elle
aussi conservée hors du FUSE, dans `/var/lib/ai-phone-stack/tailscale`, puis
recréée avec la clé injectée après redéploiement.

## Accès GitHub en écriture par clé de déploiement

Le dépôt `Nivasse14/QWEN` utilise une clé SSH de déploiement dédiée avec accès
en écriture. Sa clé privée reste sur le poste de confiance et, pendant
l'exécution, dans `/root/.ssh/ai-phone-qwen-deploy`. Elle ne doit jamais être
copiée dans `/workspace` ni ajoutée à Git.

Après un terminate/redeploy, recopier la clé depuis le poste de confiance vers
`/root/.ssh/ai-phone-qwen-deploy`, imposer le mode `0600`, puis configurer le
dépôt :

```bash
cd /workspace/ai-phone-stack
sudo ./scripts/setup-github-deploy-key.sh \
  /workspace/repos/Nivasse14/QWEN
```

Le script vérifie la clé, installe la clé d'hôte ED25519 officielle de GitHub
avec vérification stricte, et configure `origin` en SSH. La clé publique peut
rester enregistrée dans **Settings → Deploy keys** tant que ce Pod doit pousser
vers ce dépôt.

## Installation sûre de `/workspace/start-all`

Le lanceur RunPod maintient le conteneur actif, surveille la santé sans tenter
de redémarrage concurrent pendant une génération d'image, et arrête proprement
la pile à la réception de SIGTERM.

Une fois la pile présente dans `/workspace/ai-phone-stack`, prévisualiser puis installer :

```bash
cd /workspace/ai-phone-stack
sudo ./scripts/install-runpod-start-all.sh --dry-run
sudo ./scripts/install-runpod-start-all.sh
```

L'installation ne lance aucun service. Si `/workspace/start-all` existe, il est
renommé en `start-all.backup.<date>.<pid>` avant la création atomique du nouveau
lien vers `runpod-entrypoint.sh`; il n'est jamais écrasé ni supprimé. La commande
de démarrage du template peut ensuite rester `/workspace/start-all`.

Par défaut, l'entrypoint contrôle la pile toutes les 30 secondes et continue à
vivre en cas d'échec afin de laisser une session de dépannage. Pour demander au
conteneur de sortir après trois échecs consécutifs :

```bash
STACK_ENTRYPOINT_EXIT_AFTER_FAILURES=3 /workspace/start-all
```

## Persistance et cycle RunPod

Mode recommandé pour ce dépôt : volume réseau de 300 Go, monté sur `/workspace`,
avec un Pod **Secure Cloud**. Un volume réseau ne peut pas être attaché à un Pod
Community Cloud. Les scripts locaux suivent donc un cycle prudent :

```bash
./local/start-pod.sh --preview-redeploy
./local/start-pod.sh --preview-redeploy --use-fallback-gpu
./local/stop-pod.sh --terminate-redeploy --dry-run
./local/stop-pod.sh --terminate-redeploy \
  --confirm-pod-id ew6jja07rnn0cg
# Plus tard : nouveau Pod, même volume réseau.
./local/start-pod.sh
```

Ces commandes `local/` s'exécutent exclusivement sur un poste de confiance où
la nouvelle clé RunPod a été enregistrée, jamais dans le Pod :

```bash
./local/store-runpod-key.sh
```

La saisie est masquée et le fichier privé est
`${XDG_CONFIG_HOME:-$HOME/.config}/ai-phone-stack/runpod_api_key`, avec le mode
`0600`. `start-pod.sh` et `stop-pod.sh` le chargent dans `RUNPOD_API_KEY`
uniquement si cette variable est absente, sans imprimer la valeur. Elles
n'enregistrent aucune clé dans ce dépôt. L'arrêt interne `stop-stack.sh`
coupe les services mais pas la facturation GPU. Avec le volume réseau
`n10j3zet9z`, l'extinction facturable du Pod `ew6jja07rnn0cg` est une suppression
explicitement confirmée, puis un redéploiement ultérieur sur le même volume.

Le redéploiement utilise le template officiel `runpod-torch-v280`. Le CLI ne
permettant qu'un GPU par create, la RTX 3090 est un fallback manuel et sûr : si
la tentative RTX 4090 échoue, contrôler `runpodctl pod list --all` avant
`./local/start-pod.sh --use-fallback-gpu`. Aucun retry automatique ne risque
ainsi de créer deux Pods facturés.

Laisser `RUNPOD_DOCKER_ARGS` vide au premier boot conserve Jupyter/SSH. Les
secrets privés et l'identité Tailscale disparaissent avec le Pod ; lancer
immédiatement `/workspace/start-all` comme Docker CMD échouerait avant leur
réinjection. La disponibilité 4090/3090 en `EU-RO-1` et les 64 Go de RAM restent
des contrôles à effectuer au moment du redéploiement.

Le terminate/redeploy conserve le dépôt, les modèles, les données Open WebUI et
les journaux situés sur le volume. Il perd le disque conteneur, `/run`, les
secrets et l'identité Tailscale. Voir
[`docs/RUNPOD_LIFECYCLE.md`](docs/RUNPOD_LIFECYCLE.md).

La variante Community Cloud utilise un **Pod volume** de 300 Go et autorise
stop/start, mais ce volume est lié au Pod et disparaît à sa suppression. La
RTX 4090 Community publiée avec environ 41 Go de RAM ne satisfait pas la cible
de 64 Go; la machine réellement proposée doit être contrôlée avant création.

## Coûts mensuels indicatifs

Hypothèses : 730 h/mois en continu ou 180 h/mois pour 6 h/jour, 300 Go de
stockage, hors disque conteneur, taxes et variation d'offre. Les tarifs doivent
être revérifiés dans RunPod juste avant le déploiement.

| Scénario | GPU indicatif | Stockage pris en compte | 24/7 | 6 h/jour |
|---|---:|---:|---:|---:|
| **Pod actuel Secure, RTX 5090** | **0,99 $/h** | **21 $/mois** | **743,70 $** | **199,20 $** |
| Secure + volume réseau, RTX 4090 | 0,74 $/h | 21 $/mois | 561,20 $ | 154,20 $ |
| Secure + volume réseau, RTX 3090 | 0,50 $/h | 21 $/mois | 386,00 $ | 111,00 $ |
| Community + Pod volume, RTX 4090 | 0,34 $/h | 30 $ actif / 52,50 $ mixte | 278,20 $ | 113,70 $ |
| Community + Pod volume, RTX 3090 | 0,22 $/h | 30 $ actif / 52,50 $ mixte | 190,60 $ | 92,10 $ |

Calculs du volume réseau : `300 × 0,07 $ = 21 $/mois`. Pour le Pod volume,
l'estimation mixte 6 h/jour applique 0,10 $/Go/mois pendant 25 % du temps et
0,20 $/Go/mois à l'arrêt pendant 75 % du temps.

En conséquence, l'objectif de 150 $/mois n'est pas compatible avec une carte
24 Go active 24/7. Même à 6 h/jour, 300 Go de stockage rendent l'objectif
40–60 $ irréaliste dans ces scénarios. Le fallback RTX 3090 réduit le coût,
mais un plafond réellement contraignant nécessite moins d'heures, moins de
stockage ou une offre moins chère disponible au moment de la création.

## Diagnostic

```bash
./status-stack.sh
tail -n 100 /workspace/logs/{searxng,code-server,openwebui,tools-api}.log
tail -n 100 /workspace/run/ai-phone-stack/{llama-server,flux-orchestrator}.log
```

`docker-compose.yml` est uniquement une référence portable pour un hôte Linux
avec Docker. Il est volontairement placé derrière le profil `portable-host` et
ne doit pas être exécuté dans un RunPod Pod.
