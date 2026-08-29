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
# Vérifie aussi la commande de fallback, sans appel API :
./local/start-pod.sh --preview-redeploy --use-fallback-gpu

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

Le client `runpodctl pod create` accepte un seul `--gpu-id`. Le fallback est
donc volontairement **explicite**, jamais automatique : la première tentative
utilise la RTX 4090. Si elle échoue sans retourner d'ID, vérifier d'abord qu'elle
n'a créé aucun Pod, puis seulement essayer la RTX 3090 :

```bash
runpodctl pod list --all
./local/start-pod.sh --use-fallback-gpu
```

Si RunPod retourne un ID malgré une erreur, le script le mémorise et refuse tout
retry aveugle. Cette précaution évite deux Pods facturés en parallèle.

Le template officiel `runpod-torch-v280` correspond à l'image actuelle. Le
`templateId` nul du Pod existant signifie seulement que celui-ci a été créé à
partir de l'image plutôt que de ce template. Le redéploiement peut utiliser le
template officiel.

`RUNPOD_DOCKER_ARGS` reste vide au premier redéploiement. Le CMD par défaut du
template conserve Jupyter/SSH pour réinjecter les secrets privés. Pointer dès
le premier boot vers `/workspace/start-all` ferait échouer la pile : le disque
conteneur privé, `/root/.config/ai-phone-stack/secrets` et l'identité Tailscale
ont été détruits avec l'ancien Pod.

Avant terminaison, il faut donc prévoir le bootstrap du remplaçant :

1. vérifier que `/workspace/start-all` et `/workspace/ai-phone-stack` existent
   bien sur le volume réseau ;
2. disposer de nouveaux tokens GitHub et Tailscale valides dans un gestionnaire
   local, jamais sur le volume FUSE ;
3. conserver séparément la clé stable `webui_secret_key` si les données chiffrées
   Open WebUI doivent rester lisibles, et choisir un mot de passe code-server
   connu ;
4. après création, ouvrir le terminal RunPod, réinjecter les secrets avec les
   scripts à saisie masquée, puis lancer `/workspace/start-all` en arrière-plan.

La capacité RTX 4090/3090 en `EU-RO-1` et la RAM de la machine ne sont pas
garanties par ce fichier. Elles doivent être contrôlées au moment du create ; le
CLI ne propose pas de contrainte minimale de 64 Go de RAM.

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
