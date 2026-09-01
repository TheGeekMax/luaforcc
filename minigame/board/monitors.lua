--[[
  monitors.lua
  ---------------------------------------------------------------
  luaforcc :: chargeur de config partage pour les noms de moniteurs.

  Format du fichier de config (texte brut, une entree par ligne) :
    ligne 1 = nom du moniteur du joueur 1          (obligatoire)
    ligne 2 = nom du moniteur du joueur 2          (obligatoire)
    ligne 3 = nom du moniteur de controle (menu de selection de jeu,
              gere par l'appli de controle separee -- la plupart des
              jeux individuels n'en ont pas besoin et peuvent l'ignorer)
    ligne 4 = moniteur au sol du joueur 1          (optionnel)
    ligne 5 = moniteur au sol du joueur 2          (optionnel)
    ligne 6 = moniteur PARTAGE, visible des 2 joueurs (optionnel)

  Les moniteurs au sol servent aux jeux qui gagnent a etaler leur
  affichage sur deux surfaces : par exemple une bataille navale, avec
  la grille de tir au mur et sa propre flotte au sol.

  Le moniteur partage est un GRAND ecran public (pense pour du 7x6
  blocs) que les 2 joueurs voient en meme temps -- utile pour un
  plateau commun, un tableau des scores geant, etc.

  Exemple de contenu pour monitors.cfg :
    monitor_j1
    monitor_j2
    monitor_ctrl
    monitor_sol1
    monitor_sol2
    monitor_partage

  Usage depuis un jeu :
    local monitors = dofile("monitors.lua")
    local cfg = monitors.load()      -- lit "monitors.cfg" par defaut
    -- cfg.player1, cfg.player2
    -- cfg.control, cfg.floor1, cfg.floor2, cfg.shared peuvent etre nil

  Un jeu qui a besoin des ecrans au sol peut l'exiger explicitement :
    local cfg = monitors.load()
    monitors.requireFloors(cfg)      -- erreur claire s'ils manquent

  Idem pour le moniteur partage :
    monitors.requireShared(cfg)      -- erreur claire s'il manque

  Fonctionne aussi bien sous CC:Tweaked (API `fs`) que dans un
  environnement Lua classique (API `io`), pour rester testable hors jeu.
]]

local DEFAULT_PATH = "monitors.cfg"

local M = {}

local function readLines(path)
  local lines = {}

  if fs then
    if not fs.exists(path) then return nil end
    local file = fs.open(path, "r")
    if not file then return nil end
    local line = file.readLine()
    while line do
      lines[#lines + 1] = line
      line = file.readLine()
    end
    file.close()
  else
    local file = io.open(path, "r")
    if not file then return nil end
    for line in file:lines() do
      lines[#lines + 1] = line
    end
    file:close()
  end

  return lines
end

-- Charge et valide la config. Leve une erreur explicite si le
-- fichier est absent ou incomplet (mieux vaut planter tout de suite
-- avec un message clair que de demarrer avec un mauvais moniteur).
function M.load(path)
  path = path or DEFAULT_PATH
  local lines = readLines(path)

  if not lines then
    error("Fichier de config moniteurs introuvable : " .. path ..
      "\nCree-le avec au moins 2 lignes : moniteur joueur 1, moniteur joueur 2." ..
      "\nLignes optionnelles : 3 = controle, 4 et 5 = ecrans au sol, 6 = ecran partage.")
  end
  if not lines[1] or lines[1] == "" or not lines[2] or lines[2] == "" then
    error("Config moniteurs invalide (" .. path .. ") : il faut au moins 2 lignes non vides " ..
      "(moniteur joueur 1, moniteur joueur 2).")
  end

  -- une ligne absente ou vide vaut nil : les entrees optionnelles
  -- peuvent ainsi etre laissees vides sans decaler les suivantes
  local function opt(n)
    return (lines[n] and lines[n] ~= "") and lines[n] or nil
  end

  return {
    player1 = lines[1],
    player2 = lines[2],
    control = opt(3),
    floor1  = opt(4),
    floor2  = opt(5),
    shared  = opt(6),
  }
end

-- A appeler par les jeux qui ne peuvent pas tourner sans les ecrans
-- au sol, pour echouer avec un message utile plutot que sur un nil.
function M.requireFloors(cfg)
  if not cfg.floor1 or not cfg.floor2 then
    error("Ce jeu a besoin des deux moniteurs au sol.\n" ..
      "Renseigne les lignes 4 et 5 de monitors.cfg " ..
      "(sol joueur 1, sol joueur 2).")
  end
  return cfg
end

-- A appeler par les jeux qui ne peuvent pas tourner sans le moniteur
-- partage (ligne 6), pour echouer avec un message utile plutot que
-- sur un nil.
function M.requireShared(cfg)
  if not cfg.shared then
    error("Ce jeu a besoin du moniteur partage.\n" ..
      "Renseigne la ligne 6 de monitors.cfg (ecran visible des 2 joueurs).")
  end
  return cfg
end

return M