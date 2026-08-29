# Configuration native Open WebUI

La configuration active est définie par `run.sh` et non par l'interface Admin :
`ENABLE_PERSISTENT_CONFIG=false` rend les variables d'environnement
autoritaires à chaque redémarrage. Une modification faite dans l'interface peut
donc fonctionner jusqu'au prochain restart puis disparaître.

## Connexions internes

- llama-server : `http://127.0.0.1:8000/v1`, modèle
  `qwen3.8-uncensored` ;
- SearXNG : endpoint loopback défini par `SEARXNG_QUERY_URL` ;
- Tools API : `http://127.0.0.1:8002/openapi.json`, authentification Bearer ;
- orchestrateur FLUX OpenAI-compatible : `http://127.0.0.1:8003/v1` ;
- Open WebUI : écoute uniquement sur `127.0.0.1:3000`, puis Tailscale le
  publie dans le tailnet.

## Fenêtre de contexte et conversations longues

`llm/context-size.sh` fournit une valeur unique à llama-server et Open WebUI :

- 49 152 tokens sur une carte 24 Go (RTX 3090/4090) avec le cache KV Q8 ;
- 65 536 tokens à partir de 30 000 MiB de VRAM (par exemple RTX 5090 32 Go) ;
- surcharge explicite possible avec `LLAMA_CONTEXT_SIZE=32k` ou `64k` dans
  `llm/.env`.

Le lancement refuse toute version Open WebUI autre que `0.11.1`, version
installée et auditée pour ces variables de compaction. Toute mise à jour doit
d'abord revalider ce contrat et ajuster ce garde-fou.

Open WebUI 0.11.1 compacte nativement l'historique en réservant au moins
12 288 tokens et, au-delà, 25 % de la fenêtre : seuil de 20 480 en 32K,
36 864 en 48K et 49 152 en 64K. Cette marge couvre le prompt système, les
schémas d'outils et la réponse. La compaction conserve
40 % des messages récents et ajoute un résumé de l'historique retiré.

Les uploads restent en RAG borné (`RAG_FULL_CONTEXT=false`, trois fragments de
1 000 caractères avec 100 de recouvrement). Forcer le contexte complet d'un
gros fichier dans l'UI peut encore dépasser ces garde-fous.

La lecture Web est limitée à 6 000 caractères par résultat et cinq résultats,
afin qu'un seul tour de recherche ne consomme pas toute la marge réservée.

La compaction protège les conversations longues, pas un message unique plus
grand que la fenêtre. Un collage de plus de 48K/64K doit être découpé ou envoyé
comme fichier RAG.

Les clés Open WebUI, Tools API, FLUX et éventuellement llama-server sont lues
depuis `/run/secrets/ai-phone-stack`. `ENABLE_OPENAI_API_PASSTHROUGH=false`
reste obligatoire : le passthrough contournerait les contrôles de modèles en
utilisant la clé administrateur.

`ENABLE_DIRECT_CONNECTIONS=true` est actuellement nécessaire à la connexion
OpenAPI globale. Il élargit la surface d'intégration ; ne pas autoriser les
utilisateurs non administrateurs à ajouter leurs propres serveurs ou clés.

## Amorçage et modèle agent

La création du premier administrateur est encore interactive. Open WebUI
supporte officiellement `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD` et
`WEBUI_ADMIN_NAME` pour un amorçage headless, mais le superviseur actuel lance
le processus avec `env -i` et ne transmet volontairement pas ces valeurs. Ne
pas ajouter un mot de passe administrateur dans un fichier du dépôt ou sous
`/workspace`.

Après la création du premier compte, arrêter Open WebUI avant d'exécuter
`configure-model.py`. Le script vérifie le schéma SQLite et fait une sauvegarde,
mais l'édition directe de la base reste dépendante de la version Open WebUI. Une
évolution de schéma doit provoquer un arrêt, jamais une tentative de migration
automatique. À terme, préférer les endpoints officiels `/api/v1/models` avec un
jeton administrateur injecté uniquement pendant l'opération.

## Données sensibles et persistance

`WEBUI_SECRET_KEY` et les clés providers ne sont pas stockées dans la base grâce
à la configuration par environnement. En revanche, `webui.db` sous
`/workspace/open-webui-data` contient les comptes, les hashes de mots de passe,
les conversations et les uploads. Le FUSE RunPod pouvant imposer `0666`, les
autres processus du même Pod peuvent les lire.

Il n'existe pas de séparation native permettant de persister les conversations
sur ce volume tout en plaçant seulement l'authentification ailleurs. Pour une
confidentialité stricte, déplacer tout `OPENWEBUI_DATA_DIR` vers un disque privé
ou chiffrer le stockage ; cela sacrifie la survie à un terminate/redeploy si ce
disque n'est pas persistant.

## Étapes UI qui restent normales

- créer le premier administrateur, sauf ajout futur d'un amorçage secret géré ;
- vérifier que `Qwen3.8 27B — Agent mobile` expose bien les Builtin Tools et le
  serveur `AI Phone Tools` ;
- effectuer une conversation complète avec tool call puis tool result ;
- vérifier l'affichage inline d'une image.

Un `curl /v1/chat/completions` simple ne valide pas la boucle d'outils native.
