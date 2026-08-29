# Cycle de vie RunPod et volume réseau

Le mode recommandé par ces scripts est `network-volume` : un volume réseau de
300 Go déjà créé est attaché à un Pod **Secure Cloud**. RunPod ne permet pas
d'attacher ce type de volume à un Pod Community Cloud. Le stockage reste après
suppression du Pod, mais le disque conteneur et tout fichier hors du point de
montage sont perdus.

Pour cette configuration, le cycle sûr est **terminate/redeploy**. Il existe
deux niveaux d'arrêt différents :

- `stop-stack.sh`, exécuté dans le Pod, arrête les processus IA mais **ne coupe
  pas la facturation du Pod** ;
- `local/stop-pod.sh`, exécuté depuis un poste local de confiance, supprime le
  Pod RunPod. Il ne doit jamais être exécuté dans `/workspace` et aucune clé API
  RunPod ne doit être copiée sur le Pod.

Le Pod actuel est `ew6jja07rnn0cg` et son volume réseau persistant est
`n10j3zet9z`. Avant toute suppression, renseigner un vrai `RUNPOD_TEMPLATE_ID`
dans `.env.local`, puis vérifier que la commande de redéploiement peut être
construite :

```bash
cp local/env.example .env.local
# Remplir uniquement les identifiants non secrets.

# Saisir une NOUVELLE clé RunPod sans écho, sur le poste local uniquement :
./local/store-runpod-key.sh

./local/start-pod.sh --preview-redeploy

# L'arrêt simple est volontairement refusé :
./local/stop-pod.sh

# Prévisualisation sans mutation :
./local/stop-pod.sh --terminate-redeploy --dry-run

# Confirmation explicite liée à l'ID exact :
./local/stop-pod.sh --terminate-redeploy \
  --confirm-pod-id ew6jja07rnn0cg

# Plus tard, redéploie un nouveau Pod sur le même volume :
./local/start-pod.sh
```

`store-runpod-key.sh` écrit atomiquement la nouvelle clé avec le mode `0600`
dans
`${XDG_CONFIG_HOME:-$HOME/.config}/ai-phone-stack/runpod_api_key`. Le répertoire
est en `0700`. Le script refuse un chemin sous `/workspace`, un lien symbolique
ou des permissions trop ouvertes, et n'affiche jamais la valeur.

`start-pod.sh` et `stop-pod.sh` exportent `RUNPOD_API_KEY` depuis ce fichier
uniquement si la variable n'existe pas déjà dans l'environnement. Ils ne
l'affichent pas et ne la transmettent pas sur la ligne de commande. Rejouer
`store-runpod-key.sh` remplace la clé locale de façon atomique ; l'ancienne clé
doit ensuite être révoquée côté RunPod selon la politique du compte.

`start-pod.sh` mémorise seulement l'identifiant du Pod et le mode de stockage
dans `.local-state/`. Il n'enregistre aucune clé. `runpodctl` doit être déjà
authentifié via l'environnement local chargé ci-dessus. Un Pod réseau existant mais non actif n'est jamais
supprimé automatiquement : il faut confirmer avec `--terminate-redeploy`.
Après création du remplaçant, l'ID mémorisé dans `.local-state/` prévaut sur
l'ancien `RUNPOD_POD_ID` de `.env.local`.

Avant l'appel destructif, `stop-pod.sh` relit le Pod via `runpodctl pod get` et
refuse la suppression si l'ID retourné n'est pas exact ou si le volume attaché
n'est pas `n10j3zet9z`. Le flag seul ne suffit pas : l'ID doit aussi être répété
avec `--confirm-pod-id`.

La suppression conserve le volume réseau et tout ce qui est réellement sous
`/workspace`. Elle détruit le disque conteneur, `/run`, les secrets locaux et
l'identité Tailscale. Ces éléments doivent être réinjectés au nouveau Pod.

## Variante Community Cloud

Le mode `pod-volume` crée un volume Pod de 300 Go monté sur `/workspace` et
autorise `runpodctl pod stop/start`. Ce volume est lié au Pod : il survit à un
stop, mais est supprimé avec le Pod. Le mode Community Cloud et le volume réseau
sont mutuellement exclusifs.

```bash
RUNPOD_STORAGE_MODE=pod-volume ./local/start-pod.sh
RUNPOD_STORAGE_MODE=pod-volume ./local/stop-pod.sh
```

Une contrainte de 64 Go de RAM ne peut pas être demandée avec le CLI actuel ;
elle dépend de la machine qui héberge le GPU. Les profils Community publiés
peuvent donc ne pas satisfaire cette exigence, notamment la RTX 4090.
