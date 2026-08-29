# code-server + Cline sur le Pod

`setup-code-server.sh` installe une version vérifiée de code-server et une
version épinglée de Cline. `start-code-server.sh` garde les éléments sensibles
hors du volume FUSE `/workspace` :

- état utilisateur, historique Cline et SecretStorage :
  `/var/lib/ai-phone-stack/code-server` ;
- mot de passe et configuration de démarrage : `/run/ai-phone-stack` et
  `/run/secrets/ai-phone-stack` ;
- seuls les binaires et extensions, non secrets, sont persistés dans
  `/workspace/ai-phone-stack/.runtime`.

Cette séparation a une conséquence volontaire : après un terminate/redeploy du
Pod, il faut reconnecter Cline et `gh`. Une simple suspension/reprise du même
conteneur conserve normalement `/var/lib`, mais ce répertoire ne constitue pas
une sauvegarde durable.

## Limite de configuration headless de l'extension

Cline ne publie pas de paramètre VS Code stable pour injecter le provider, son
URL, le modèle et la clé. Les paramètres non sensibles vivent dans le global
state de l'extension et les clés dans VS Code SecretStorage. Modifier directement
`state.vscdb` ou les fichiers `globalStorage` serait dépendant de la version et
risquerait de corrompre le coffre.

La partie headless sûre couvre donc l'installation, le stockage, le réseau et
les réglages VS Code publics. Les quatre champs provider restent une étape UI
unique et explicite.

## Première configuration dans l'interface mobile

1. Ouvrir code-server via son URL Tailscale HTTPS, puis ouvrir **Cline**.
2. Dans les réglages Cline, choisir **OpenAI Compatible**.
3. Renseigner l'URL `http://127.0.0.1:8000/v1`.
4. Renseigner le modèle `qwen3.8-uncensored`.
5. Régler la fenêtre sur `49152` pour une RTX 3090/4090 24 Go, ou `65536`
   pour une carte 32 Go lorsque `llm/context-size.sh` affiche cette valeur.
   Conserver la sortie maximale à `4096`. Ne pas activer « Supports Images » tant que llama-server
   n'est pas lancé avec le projecteur multimodal `--mmproj`.
6. Si llama-server est local sans authentification, saisir comme clé la valeur
   non secrète `local-loopback-only`. Si `LLAMA_REQUIRE_API_KEY=1`, saisir la
   vraie clé uniquement dans l'interface Cline ; elle sera stockée dans le
   SecretStorage privé sous `/var/lib`, jamais dans `/workspace`.
7. Vérifier les modes Plan et Act : selon la version de Cline, leur sélection de
   modèle peut être distincte.

Ne pas activer les approbations automatiques globales. Qwen quantifié doit
d'abord réussir un test lecture → modification → test → diff. Les réglages
préchargés désactivent également le navigateur Cline et l'auto-forwarding de
ports ; la recherche web reste assurée par Open WebUI.

## GitHub dans code-server

`gh` reste plus fiable que l'extension GitHub Authentication dans un navigateur
mobile. Depuis le terminal intégré :

```bash
gh auth login
```

Privilégier le flux navigateur/device. Si un token finement limité doit être
utilisé, le fournir à `gh auth login --with-token` par l'entrée standard. Le
HOME du terminal est `/var/lib/ai-phone-stack/code-server/home`, donc la
configuration `gh` ne va pas sur le volume FUSE. Ne jamais placer un token dans
une URL Git, `settings.json`, `.env`, le dépôt ou l'historique shell.

## Contrôles après démarrage

Ces contrôles ne révèlent aucune clé :

```bash
curl -fsS http://127.0.0.1:8000/v1/models
gh auth status
```

Puis demander à Cline, dans un dépôt de test, de lire un fichier, faire une
petite modification, lancer un test et montrer le diff. Le premier push doit
rester manuel et viser une branche dédiée.
