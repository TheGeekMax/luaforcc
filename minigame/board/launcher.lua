--[[
  launcher.lua
  ---------------------------------------------------------------
  luaforcc :: programme de controle -- liste automatiquement les
  jeux presents dans /home et affiche un bouton pour lancer chacun
  d'eux, sur l'ecran de CONTROLE (monitors.cfg ligne 3).

  Fonctionnement :
    - Scanne /home, ne garde que les fichiers .lua.
    - Exclut monitors.lua, monitors.cfg et launcher.lua lui-meme
      (ce ne sont pas des jeux).
    - Un bouton par jeu trouve. Le lancer bloque le launcher tant
      que le jeu tourne (normal : le jeu prend la main sur son
      propre event loop) ; des que le joueur quitte le jeu (bouton
      Quitter DANS le jeu), on revient au menu.
    - PAS de bouton pour quitter le launcher lui-meme : par choix,
      on ferme en arretant le programme depuis l'ordinateur
      (Ctrl+T, ou en le retirant/cassant).

  N'utilise qu'UN SEUL moniteur (celui de controle). Pas de main a
  cacher, pas de tour a gerer -- juste un menu.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 0.5
local GAMES_DIR = "/home"

-- Fichiers a NE JAMAIS proposer comme jeu, meme s'ils sont en .lua
-- dans /home.
local EXCLUDE = {
  ["monitors.lua"] = true,
  ["monitors.cfg"] = true,
  ["launcher.lua"] = true,
  ["subpixel.lua"] = true,
}

-- ============================================================
-- LOGIQUE PURE (scan de repertoire + mise en forme des noms) --
-- injectable via un `fsLike` pour rester testable hors CC.
-- ============================================================

-- Transforme "connect4_game.lua" -> "Connect4", "familles_game.lua"
-- -> "Familles", etc. Retire l'extension puis le suffixe "_game" si
-- present, remplace les underscores restants par des espaces, met
-- une majuscule a chaque mot.
local function prettyLabel(filename)
  local base = filename:gsub("%.lua$", "")
  base = base:gsub("_game$", "")
  base = base:gsub("_", " ")
  base = base:gsub("(%a)([%w']*)", function(first, rest) return first:upper() .. rest:lower() end)
  return base
end

-- `fsLike` doit fournir .exists(path), .list(path), .isDir(path),
-- .combine(a,b) -- signature identique a l'API CC `fs`, pour pouvoir
-- injecter un faux systeme de fichiers en test.
local function findGames(fsLike, dir)
  local games = {}
  if not fsLike.exists(dir) then return games end
  local entries = fsLike.list(dir)
  for _, name in ipairs(entries) do
    local fullPath = fsLike.combine(dir, name)
    if not fsLike.isDir(fullPath) and name:match("%.lua$") and not EXCLUDE[name] then
      games[#games + 1] = { name = name, path = fullPath, label = prettyLabel(name) }
    end
  end
  table.sort(games, function(a, b) return a.label < b.label end)
  return games
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

_G.__launcher_internal = {
  prettyLabel = prettyLabel,
  findGames = findGames,
  EXCLUDE = EXCLUDE,
}

if _G.__LAUNCHER_TEST_MODE then return end

-- ============================================================
-- A PARTIR D'ICI : peripheriques, rendu, boucle
-- (non charge en mode test)
-- ============================================================

local function scriptDir()
  if shell and shell.getRunningProgram then
    local p = shell.getRunningProgram()
    if p then return fs.getDir(p) end
  end
  return nil
end

local function resolveNear(filename)
  local dir = scriptDir()
  if dir and dir ~= "" then
    return fs.combine(dir, filename)
  end
  return filename
end

-- Met a jour le repertoire de jeux via l'outil vcsu avant de
-- demarrer (recupere les dernieres versions depuis le depot
-- TheGeekMax/luaforcc). vcsu travaille dans le repertoire COURANT du
-- shell (pas forcement /home) : on le force explicitement, puis on
-- restaure l'ancien apres coup pour ne pas laisser le shell dans un
-- etat surprenant si on quitte le launcher. N'empeche pas le
-- lancement si ca echoue (pas de reseau, vcsu absent, etc.) : le
-- launcher continue avec ce qui est deja present sur place.
if shell and shell.run then
  local prevDir = shell.dir and shell.dir() or nil
  if shell.setDir then shell.setDir(GAMES_DIR) end

  local ok = pcall(shell.run, "vcsu", "get", "games")

  if prevDir and shell.setDir then shell.setDir(prevDir) end
  if not ok then
    print("Avertissement : 'vcsu get games' a echoue -- on continue avec les jeux deja presents.")
  end
end

local monitorsLib = dofile(resolveNear("monitors.lua"))
local monitorCfg = monitorsLib.load(resolveNear(MONITORS_CONFIG_PATH))
local CONTROL_NAME = monitorCfg.control
if not CONTROL_NAME then
  error("Aucun moniteur de controle configure : renseigne la ligne 3 de " .. MONITORS_CONFIG_PATH)
end

local mon = peripheral.wrap(CONTROL_NAME)
if not mon then
  error("Moniteur de controle introuvable : '" .. CONTROL_NAME .. "' (ligne 3 de " .. MONITORS_CONFIG_PATH .. ")")
end
mon.setTextScale(TEXT_SCALE)

-- ------------------------------------------------------------
-- Rendu
-- ------------------------------------------------------------

local BTN_W, BTN_H = 16, 3

local function drawButton(mon, x, y, w, h, label, bg, fg)
  for row = 0, h - 1 do
    mon.setCursorPos(x, y + row)
    mon.setBackgroundColor(bg)
    mon.write(string.rep(" ", w))
  end
  local label_row = math.floor((h - 1) / 2)
  local label_x = x + math.max(0, math.floor((w - #label) / 2))
  mon.setCursorPos(label_x, y + label_row)
  mon.setTextColor(fg)
  mon.write(label)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

-- Rendu du menu. Retourne les zones cliquables : { {x1,y1,x2,y2,
-- path=}, ... }. Une grille adaptative, jamais de chevauchement --
-- si trop de jeux pour la hauteur disponible, les derniers sortent
-- simplement du cadre plutot que de deborder sur autre chose.
local function renderMenu(games)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write("== Programme de controle ==")
  mon.setCursorPos(1, 2)
  mon.setTextColor(colors.lightGray)
  mon.write(#games .. " jeu(x) disponible(s) dans " .. GAMES_DIR)
  mon.setTextColor(colors.white)

  if #games == 0 then
    mon.setCursorPos(1, 4)
    mon.setTextColor(colors.red)
    mon.write("Aucun jeu trouve.")
    mon.setTextColor(colors.white)
    return clickZones
  end

  local startY = 4
  local cols = math.max(1, math.floor(w / (BTN_W + 1)))
  local slotW, slotH = BTN_W + 1, BTN_H + 1

  for i, game in ipairs(games) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local x = 1 + col * slotW
    local y = startY + row * slotH
    if y + BTN_H - 1 <= h then
      drawButton(mon, x, y, BTN_W, BTN_H, game.label, colors.lightGray, colors.black)
      clickZones[#clickZones + 1] = {
        x1 = x, y1 = y, x2 = x + BTN_W - 1, y2 = y + BTN_H - 1, path = game.path, name = game.name,
      }
    end
  end

  return clickZones
end

local function zoneAt(zones, x, y)
  for _, z in ipairs(zones) do
    if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z end
  end
  return nil
end

local function fsAdapter()
  return {
    exists = fs.exists,
    list = fs.list,
    isDir = fs.isDir,
    combine = fs.combine,
  }
end

local function launchGame(path)
  mon.setBackgroundColor(colors.black)
  mon.clear()
  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write("Lancement en cours...")

  if shell and shell.run then
    shell.run(path)
  else
    local ok, err = pcall(dofile, path)
    if not ok then
      print("Erreur dans " .. path .. " : " .. tostring(err))
    end
  end
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

print("Programme de controle lance sur " .. CONTROL_NAME .. ". (Ctrl+T pour arreter le launcher lui-meme)")

local lastClickZones = {}
_G.__LAUNCHER_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

local function redraw()
  local games = findGames(fsAdapter(), GAMES_DIR)
  lastClickZones = renderMenu(games)
end

redraw()

if _G.__LAUNCHER_AUTOPILOT then
  local launchesLeft = _G.__LAUNCHER_AUTOPILOT_LAUNCHES or 1
  while launchesLeft > 0 do
    if #lastClickZones == 0 then
      error("Aucune zone cliquable -- deadlock UI possible")
    end
    local chosen = lastClickZones[math.random(#lastClickZones)]
    launchGame(chosen.path)
    redraw()
    launchesLeft = launchesLeft - 1
  end
  print("AUTOPILOT OK")
  return
end

while true do
  local event, side, x, y = os.pullEvent("monitor_touch")
  if side == CONTROL_NAME then
    local zone = zoneAt(lastClickZones, x, y)
    if zone then
      launchGame(zone.path)
      redraw()
    end
  end
end