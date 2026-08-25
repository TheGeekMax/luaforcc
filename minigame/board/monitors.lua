--[[
  monitors.lua
  ---------------------------------------------------------------
  luaforcc :: chargeur de config partage pour les noms de moniteurs.

  Format du fichier de config (texte brut, 3 lignes) :
    ligne 1 = nom du moniteur du joueur 1
    ligne 2 = nom du moniteur du joueur 2
    ligne 3 = nom du moniteur de controle (menu de selection de jeu,
              gere par l'appli de controle separee -- la plupart des
              jeux individuels n'en ont pas besoin et peuvent l'ignorer)

  Exemple de contenu pour monitors.cfg :
    monitor_j1
    monitor_j2
    monitor_ctrl

  Usage depuis un jeu :
    local monitors = dofile("monitors.lua")
    local cfg = monitors.load()      -- lit "monitors.cfg" par defaut
    -- cfg.player1, cfg.player2, cfg.control (control peut etre nil)

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
      "\nCree-le avec 3 lignes : moniteur joueur 1, moniteur joueur 2, moniteur de controle.")
  end
  if not lines[1] or lines[1] == "" or not lines[2] or lines[2] == "" then
    error("Config moniteurs invalide (" .. path .. ") : il faut au moins 2 lignes non vides " ..
      "(moniteur joueur 1, moniteur joueur 2).")
  end

  return {
    player1 = lines[1],
    player2 = lines[2],
    control = (lines[3] and lines[3] ~= "") and lines[3] or nil,
  }
end

return M