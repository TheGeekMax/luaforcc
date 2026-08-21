# luaforcc

Mes programmes Lua pour **ComputerCraft / CC:Tweaked**.

Les scripts s'installent directement depuis ce depot sur n'importe quel ordinateur ou tortue, via l'outil `vcs` inclus ici.

---

## Installation

Une seule ligne sur une machine neuve :

```
wget https://raw.githubusercontent.com/TheGeekMax/luaforcc/refs/heads/main/vcs/install install
install
vcs config TheGeekMax/luaforcc
```

Cela met en place `vcs` et `vcsu` dans `/scripts`, les rend accessibles depuis n'importe quel dossier, et les branche sur ce depot.

Ensuite, pour installer un projet :

```
cd /home
vcsu get <projet>
```

---

## Projets

| Projet | Description |
|---|---|
| [`vcs`](vcs/) | Gestionnaire de scripts : recupere fichiers et projets depuis ce depot |

---

## Structure

```
luaforcc/
├── vcs/            <- l'outillage (install, vcs, vcsu)
├── download/       <- manifestes d'installation, un par projet
└── <projet>/       <- un dossier par programme
```

Le dossier `download/` contient un fichier sans extension par projet installable. Chacun liste les fichiers a recuperer et ou les placer - voir la [documentation de vcs](vcs/README.md) pour le format.

---

## Prerequis

CC:Tweaked avec l'API HTTP activee et `raw.githubusercontent.com` autorise, ce qui est le cas par defaut dans la plupart des modpacks.