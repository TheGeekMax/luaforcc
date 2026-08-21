# vcs

Gestionnaire de scripts pour **CC:Tweaked**, adosse a un depot GitHub. Livre avec `vcsu`, son pendant pour les projets multi-fichiers.

Plutot que de retaper une URL `wget` a rallonge sur chaque ordinateur et chaque tortue, on configure le depot une fois, puis on recupere les fichiers par leur chemin. `vcsu` va plus loin : il installe un projet entier - plusieurs fichiers, leurs dependances et leur script de demarrage - en une commande.

---

## Sommaire

- [Installation](#installation)
- [Demarrage rapide](#demarrage-rapide)
- [vcs - fichiers individuels](#vcs---fichiers-individuels)
- [vcsu - projets complets](#vcsu---projets-complets)
- [Creer un projet](#creer-un-projet)
- [Organisation du depot](#organisation-du-depot)
- [Comment ca marche](#comment-ca-marche)
- [Depannage](#depannage)

---

## Installation

Sur une machine neuve, une seule ligne a taper :

```
wget https://raw.githubusercontent.com/TheGeekMax/luaforcc/refs/heads/main/vcs/install install
install
```

L'installeur :

1. cree `/scripts` et y telecharge `vcs` et `vcsu` ;
2. cree `/home`, prevu pour tes propres scripts ;
3. ajoute `/scripts` au `PATH` du shell, de facon **persistante** (une ligne ecrite dans `/startup.lua`) ;
4. applique ce `PATH` immediatement - pas besoin de redemarrer.

Relancer `install` est sans danger : la ligne de `PATH` n'est pas dupliquee.

Ensuite, indique le depot dans lequel `vcs` et `vcsu` iront chercher les scripts. Ce n'est pas forcement celui d'ou vient l'outillage, meme si les deux peuvent coincider :

```
vcs config <owner/repo> [branche]
```

La branche vaut `main` par defaut. La configuration est stockee dans `/.vcsconfig` et partagee par `vcs` et `vcsu`.

---

## Demarrage rapide

```
install
vcs config TheGeekMax/luaforcc
cd /home
vcsu get monitoring
```

---

## vcs - fichiers individuels

| Commande | Effet |
|---|---|
| `vcs config <owner/repo> [branche]` | Definit le depot source |
| `vcs info` | Affiche la configuration et les fichiers suivis |
| `vcs get <chemin>` | Telecharge un fichier dans le dossier courant |
| `vcs update` | Retelecharge tous les fichiers suivis |

### `vcs get`

Le chemin donne est celui **dans le depot**. Le fichier atterrit au meme chemin relatif, a partir du dossier courant :

```
cd /home
vcs get widgets/graph.lua     -->  /home/widgets/graph.lua
```

Les sous-dossiers manquants sont crees au besoin. Un chemin commencant par `/` est traite comme absolu et ignore le dossier courant.

Si le telechargement echoue (chemin errone, reseau coupe), le fichier local existant **n'est pas touche** : le contenu distant est recupere integralement avant tout ecrasement.

### `vcs update`

Chaque fichier recupere - que ce soit par `vcs get` ou par `vcsu get` - est enregistre dans `/.vcsconfig` avec sa destination absolue. `vcs update` les repasse tous en revue et affiche un bilan.

Comme les destinations sont absolues, `update` fonctionne depuis n'importe quel dossier. Un echec sur un fichier n'interrompt pas les autres.

> `vcs update` ne relit pas les manifestes. Une ligne ajoutee a un manifeste, ou un `#startup:` modifie, ne sera pris en compte qu'au prochain `vcsu get`.

---

## vcsu - projets complets

| Commande | Effet |
|---|---|
| `vcsu get <projet> [--no-startup]` | Installe un projet entier |
| `vcsu list <projet>` | Affiche ce qui serait installe, sans rien ecrire |

Un "projet" est un fichier **manifeste** place dans `download/` a la racine du depot. Il liste les fichiers a recuperer, leur destination locale, et eventuellement un script de demarrage.

### `vcsu list`

A lancer avant tout `get` sur un projet inconnu. Affiche l'arbre des manifestes resolus (includes compris), la liste complete des fichiers avec leur destination reelle, et le script de demarrage retenu. Aucune ecriture disque.

### `vcsu get`

Deroule :

1. **Resolution** - recupere le manifeste, suit les `#include:`, construit la liste finale des fichiers.
2. **Telechargement** - uniquement si la resolution a entierement reussi.
3. **Demarrage** - ecrit le bloc `#startup:` dans `/startup.lua`, sauf si un fichier a echoue ou si `--no-startup` est passe.

Si un manifeste inclus est introuvable, l'operation s'arrete **avant** le moindre telechargement. Rien n'est ecrit a moitie.

---

## Creer un projet

### 1. Placer les fichiers dans le depot

Organise-les comme tu veux :

```
widgets/graph.lua
widgets/gauge.lua
monitoring/main.lua
monitoring/config.lua
```

### 2. Ecrire le manifeste

Un fichier **sans extension** dans `download/`, nomme d'apres le projet :

```
download/monitoring
```

Contenu :

```
-- Tableau de bord de monitoring
-- v1.0

#include: widgets
#startup: main.lua

monitoring/main.lua::main.lua
monitoring/config.lua::config.lua
```

### 3. Installer

```
cd /home
vcsu get monitoring
```

---

### Syntaxe des manifestes

#### Fichiers

```
chemin/dans/le/depot::chemin/local
```

La partie gauche est le chemin dans le depot, la droite la destination, **relative au dossier courant** au moment du `vcsu get`. Les sous-dossiers sont crees automatiquement.

```
widgets/graph.lua::lib/graph.lua
```
Lance depuis `/home`, ce fichier atterrit dans `/home/lib/graph.lua`.

#### Commentaires

Une ligne commencant par `--` est ignoree :

```
-- ceci est un commentaire
```

Les commentaires en fin de ligne fonctionnelle ne sont **pas** supportes :

```
monitoring/main.lua::main.lua   -- ceci casse la ligne
```

#### `#include:`

Insere les fichiers d'un autre projet :

```
#include: widgets
```

Les includes sont recursifs et peuvent s'imbriquer. Un projet deja traite est ignore s'il revient une deuxieme fois, ce qui rend les cycles inoffensifs. Un fichier declare deux fois vers la meme destination n'est telecharge qu'une fois.

Utile pour factoriser une bibliotheque partagee entre plusieurs projets.

#### `#startup:`

Designe le fichier a lancer au demarrage de la machine. La valeur est un chemin **local** - la destination apres telechargement, pas le chemin dans le depot :

```
monitoring/main.lua::main.lua
#startup: main.lua
```

Installe depuis `/home`, ce bloc est ecrit dans `/startup.lua` :

```lua
-- >>> vcsu startup >>>
shell.run("/home/main.lua")
-- <<< vcsu startup <<<
```

Le bloc est delimite par des marqueurs, ce qui le rend remplacable : un nouveau `vcsu get` avec un `#startup:` ecrase l'ancien bloc au lieu d'en empiler un second. Il ne peut donc y avoir qu'**un seul** programme de demarrage gere par `vcsu`, et le reste de `/startup.lua` - notamment la ligne de `PATH` posee par `install` - reste intact.

Si plusieurs `#startup:` sont declares via des includes, celui du projet demande en ligne de commande l'emporte, et un avertissement liste les candidats.

Pour installer un projet sans toucher au demarrage :

```
vcsu get monitoring --no-startup
```

---

## Organisation du depot

Un meme depot peut heberger a la fois l'outillage et les projets qu'il distribue :

```
luaforcc/
├── vcs/                    <- l'outillage lui-meme
│   ├── install
│   ├── vcs
│   └── vcsu
├── download/               <- manifestes, sans extension
│   ├── monitoring
│   ├── widgets
│   └── mining
├── widgets/                <- les projets
│   ├── graph.lua
│   └── gauge.lua
├── monitoring/
│   ├── main.lua
│   └── config.lua
└── mining/
    └── turtle.lua
```

Deux emplacements sont fixes : `download/` doit etre a la racine du depot, et `install` pointe en dur vers le dossier qui contient `vcs` et `vcsu`. Le reste s'organise librement.

`install` et `vcs config` sont independants : le premier va toujours chercher l'outillage la ou il est publie, le second designe le depot dans lequel `vcs get` et `vcsu get` iront puiser. Ici les deux coincident, mais rien n'empeche de configurer `vcs` sur un depot de scripts entierement distinct.

---

## Comment ca marche

**Recuperation** - les fichiers sont lus via `raw.githubusercontent.com`. Le depot doit donc etre public, et aucun jeton n'est necessaire. La construction de l'URL est isolee dans une seule fonction (`buildRawURL`), ce qui permet de basculer vers un CDN comme jsDelivr en changeant une ligne.

**Configuration** - `/.vcsconfig` est un fichier Lua serialise (`textutils.serialize`), en chemin absolu pour rester unique quel que soit le dossier d'appel. Il contient le depot, la branche, et la liste des fichiers suivis sous la forme `{ remote, dest }`.

**Chemins** - les fonctions `fs.*` de CC:Tweaked travaillent depuis la racine et ignorent le dossier courant du shell. Les chemins relatifs sont donc resolus explicitement via `shell.resolve()` avant tout acces disque.

**Ecriture** - un fichier local n'est supprime qu'une fois le contenu distant integralement recu et non vide.

---

## Depannage

**"Aucune config trouvee"** - lancer `vcs config <owner/repo>` au prealable.

**Les fichiers atterrissent au mauvais endroit** - les destinations sont relatives au dossier courant. Verifier avec `vcsu list`, qui affiche les chemins absolus reels avant toute ecriture.

**Une modification poussee sur GitHub n'apparait pas** - `raw.githubusercontent.com` sert avec un cache de quelques minutes. Attendre, ou pousser un nouveau commit.

**"Ligne ignoree (format invalide)"** - le separateur `::` est absent ou l'un des deux cotes est vide. Le message indique le manifeste et le numero de ligne. Penser aussi aux commentaires en fin de ligne, qui ne sont pas supportes.

**Le script de demarrage ne se lance pas** - verifier que le `#startup:` designe bien un chemin *local* et non un chemin du depot, et inspecter `/startup.lua` avec `edit /startup.lua`. Le bloc n'est pas ecrit si un telechargement a echoue.

**Erreur HTTP** - l'API HTTP doit etre activee cote serveur, et le domaine `raw.githubusercontent.com` autorise dans la configuration de CC:Tweaked. C'est le cas par defaut dans la plupart des modpacks.