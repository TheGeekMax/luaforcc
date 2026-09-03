--[[
  knucklebones_game.lua
  ---------------------------------------------------------------
  luaforcc :: Knucklebones (jeu de des de Cult of the Lamb), 2 joueurs.

  AUCUNE information cachee dans ce jeu (contrairement a Uno/Bataille
  navale) : les 2 grilles sont toujours visibles de tout le monde.
  Repartition des ecrans prevue :

    - ECRAN MURAL de chaque joueur (monitors.cfg lignes 1/2) : les 2
      grilles empilees A LA VERTICALE (orientation portrait). C'est
      aussi l'ecran d'ACTION : seul le joueur dont c'est le tour y
      voit ses colonnes cliquables pour poser son de.

    - ECRAN PARTAGE (ligne 6) : les 2 grilles cote a cote A
      L'HORIZONTALE (orientation paysage), pour une vue d'ensemble
      confortable -- purement informatif, jamais tactile.

  Regles (rappel) :
    - Grille 3 colonnes x 3 cases par joueur.
    - A son tour : lancer d'un de (1-6), pose dans une colonne NON
      PLEINE de sa propre grille.
    - Poser un de de valeur V detruit TOUS les des de valeur V dans
      la colonne EN FACE (meme index) chez l'adversaire.
    - Score d'une colonne : les des identiques d'une meme colonne se
      regroupent et se multiplient entre eux (valeur x nb^2) ; les
      groupes de valeurs differentes s'additionnent normalement.
    - Score total = somme des 3 colonnes.
    - Fin de partie : des qu'un joueur remplit ses 9 cases. Le plus
      haut score total gagne (egalite possible -> match nul).

  Sous-pixel (subpixel.lua) envisage pour dessiner les faces de des
  en pixel art plutot qu'en simple chiffre -- decision remise a la
  phase d'affichage.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 0.5
local COLS, ROWS = 3, 3 -- 3 colonnes, 3 cases par colonne

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

-- Represantation d'une grille : grid[col] = liste COMPACTE des des
-- deja poses dans cette colonne, dans l'ordre de pose (index 1 =
-- le plus bas, donc le premier pose). Pas de "trous" representes :
-- une colonne a 0, 1, 2 ou 3 elements. C'est un choix delibere --
-- ca rend la destruction+tassement vers le bas gratuite (voir
-- destroyMatching plus bas : un simple filtre suffit).

-- ------------------------------------------------------------
-- SCORING -- implemente et teste en premier (voir demande initiale).
-- Fonctionne aussi bien sur une liste compacte (sans 0) que sur une
-- liste de 3 valeurs avec des 0 pour les cases vides : ipairs()
-- s'arrete au premier trou de toute facon, et les 0 explicites sont
-- ignores.
-- ------------------------------------------------------------
local function scoreColumn(column)
  local counts = {}
  for _, v in ipairs(column) do
    if v ~= 0 and v ~= nil then
      counts[v] = (counts[v] or 0) + 1
    end
  end

  local total = 0
  for v, k in pairs(counts) do
    total = total + v * k * k
  end
  return total
end

-- Score total d'une grille complete (3 colonnes) : simple somme des
-- 3 scores de colonne.
local function scoreGrid(grid)
  local total = 0
  for col = 1, COLS do
    total = total + scoreColumn(grid[col])
  end
  return total
end

-- ------------------------------------------------------------
-- Reste du moteur
-- ------------------------------------------------------------

local function otherSide(side) return (side == "player1") and "player2" or "player1" end

local function isColumnFull(column)
  return #column >= ROWS
end

local function rollDie()
  return math.random(1, 6)
end

local function newGame()
  local function emptyGrid()
    return { {}, {}, {} }
  end

  return {
    grids = { player1 = emptyGrid(), player2 = emptyGrid() },
    currentPlayer = "player1",
    currentRoll = rollDie(), -- le de est lance automatiquement des le debut du tour
    gameOver = false,
    winner = nil, -- "player1" | "player2" | "draw"
  }
end

-- Retire tous les des de valeur `value` de `column`, en preservant
-- l'ordre relatif des survivants -- ce qui EST le tassement vers le
-- bas (le survivant le plus bas reste le plus bas, aucun trou ne
-- peut jamais exister dans une liste compacte).
local function destroyMatching(column, value)
  local kept = {}
  for _, v in ipairs(column) do
    if v ~= value then kept[#kept + 1] = v end
  end
  return kept
end

-- La grille de `player` est-elle pleine (9/9) ? Si oui, termine la
-- partie et designe le vainqueur (meilleur scoreGrid, ou match nul).
local function checkGameEnd(G, player)
  local grid = G.grids[player]
  for col = 1, COLS do
    if not isColumnFull(grid[col]) then return false end
  end

  G.gameOver = true
  local s1 = scoreGrid(G.grids.player1)
  local s2 = scoreGrid(G.grids.player2)
  if s1 > s2 then
    G.winner = "player1"
  elseif s2 > s1 then
    G.winner = "player2"
  else
    G.winner = "draw"
  end
  return true
end

-- `player` place son de courant (G.currentRoll) dans la colonne
-- `col` de SA PROPRE grille.
local function placeDie(G, player, col)
  if G.gameOver then return false end
  if G.currentPlayer ~= player then return false end
  if col < 1 or col > COLS then return false end
  local myColumn = G.grids[player][col]
  if isColumnFull(myColumn) then return false end

  local value = G.currentRoll
  myColumn[#myColumn + 1] = value

  -- destruction en face (meme index de colonne) chez l'adversaire
  local opponent = otherSide(player)
  G.grids[opponent][col] = destroyMatching(G.grids[opponent][col], value)

  if not checkGameEnd(G, player) then
    G.currentPlayer = opponent
    G.currentRoll = rollDie()
  else
    G.currentRoll = nil
  end

  return true
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

_G.__kb_internal = {
  scoreColumn = scoreColumn,
  scoreGrid = scoreGrid,
  newGame = newGame,
  rollDie = rollDie,
  isColumnFull = isColumnFull,
  destroyMatching = destroyMatching,
  placeDie = placeDie,
  checkGameEnd = checkGameEnd,
  COLS = COLS,
  ROWS = ROWS,
}

if _G.__KB_TEST_MODE then return end

-- ============================================================
-- A PARTIR D'ICI : peripheriques, rendu, boucle de jeu
-- ============================================================

math.randomseed(os.epoch and os.epoch("utc") or os.time())

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

local monitorsLib = dofile(resolveNear("monitors.lua"))
local subpixel = dofile(resolveNear("subpixel.lua"))
local monitorCfg = monitorsLib.load(resolveNear(MONITORS_CONFIG_PATH))
monitorsLib.requireShared(monitorCfg)

local WALL_1_NAME = monitorCfg.player1
local WALL_2_NAME = monitorCfg.player2
local SHARED_NAME = monitorCfg.shared

local wall1 = peripheral.wrap(WALL_1_NAME)
local wall2 = peripheral.wrap(WALL_2_NAME)
local shared = peripheral.wrap(SHARED_NAME)
for _, entry in ipairs({ { WALL_1_NAME, wall1 }, { WALL_2_NAME, wall2 }, { SHARED_NAME, shared } }) do
  if not entry[2] then
    error("Moniteur introuvable : '" .. entry[1] .. "' (defini dans " .. MONITORS_CONFIG_PATH .. ")")
  end
end
wall1.setTextScale(TEXT_SCALE)
wall2.setTextScale(TEXT_SCALE)
shared.setTextScale(TEXT_SCALE)

local SCREENS = {
  player1 = { mon = wall1, side = "player1" },
  player2 = { mon = wall2, side = "player2" },
}
local SCREEN_KEYS = { "player1", "player2" }
local NAME_TO_KEY = { [WALL_1_NAME] = "player1", [WALL_2_NAME] = "player2" }
-- (le moniteur partage n'est jamais tactile -- purement informatif)

local SIDE_LABEL = { player1 = "Joueur 1", player2 = "Joueur 2" }

-- ------------------------------------------------------------
-- Faces de de en pixel art sub-pixel (vraies pastilles, comme un
-- vrai de) : fond blanc, pastilles noires, disposition classique.
-- ------------------------------------------------------------

local DIE_PIX_W, DIE_PIX_H = 12, 12 -- taille "mur" -> 6 caracteres x 4 caracteres
local SHARED_DIE_PIX_W, SHARED_DIE_PIX_H = 30, 30 -- taille "partage" -> 15 x 10 caracteres, bien plus gros

-- Positions des pastilles exprimees en FRACTIONS (0..1) de la
-- taille de l'icone, pour rester valables quelle que soit la taille
-- de de choisie (mur ou partage).
local PIP_POS_FRAC = {
  topLeft = { 0.25, 0.25 }, topRight = { 0.75, 0.25 },
  midLeft = { 0.25, 0.5 }, midRight = { 0.75, 0.5 }, center = { 0.5, 0.5 },
  botLeft = { 0.25, 0.75 }, botRight = { 0.75, 0.75 },
}
local PIP_PATTERNS = {
  [1] = { "center" },
  [2] = { "topLeft", "botRight" },
  [3] = { "topLeft", "center", "botRight" },
  [4] = { "topLeft", "topRight", "botLeft", "botRight" },
  [5] = { "topLeft", "topRight", "center", "botLeft", "botRight" },
  [6] = { "topLeft", "topRight", "midLeft", "midRight", "botLeft", "botRight" },
}

local function paintPip(grid, pixW, pixH, cx, cy, radius)
  for row = math.max(1, cy - radius), math.min(pixH, cy + radius) do
    for col = math.max(1, cx - radius), math.min(pixW, cx + radius) do
      grid[row][col] = colors.black
    end
  end
end

local DIE_ICON_CACHE = {}
local function buildDieIcon(value, pixW, pixH)
  pixW = pixW or DIE_PIX_W
  pixH = pixH or DIE_PIX_H
  local cacheKey = value .. ":" .. pixW .. "x" .. pixH
  if DIE_ICON_CACHE[cacheKey] then return DIE_ICON_CACHE[cacheKey] end

  local g = subpixel.newGrid(pixW, pixH, colors.white)
  local radius = math.max(1, math.floor(math.min(pixW, pixH) / 8))
  for _, posName in ipairs(PIP_PATTERNS[value]) do
    local p = PIP_POS_FRAC[posName]
    local cx = math.floor(p[1] * pixW + 0.5)
    local cy = math.floor(p[2] * pixH + 0.5)
    paintPip(g, pixW, pixH, cx, cy, radius)
  end
  DIE_ICON_CACHE[cacheKey] = g
  return g
end

local DIE_CHAR_W, DIE_CHAR_H = DIE_PIX_W / 2, DIE_PIX_H / 3 -- 6 x 4
local SHARED_DIE_CHAR_W, SHARED_DIE_CHAR_H = SHARED_DIE_PIX_W / 2, SHARED_DIE_PIX_H / 3 -- 15 x 10

-- ------------------------------------------------------------
-- Rendu generique
-- ------------------------------------------------------------

local function drawButton(mon, x, y, w, label, bg, fg)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg or colors.lightGray)
  mon.write(string.rep(" ", w))
  mon.setCursorPos(x + math.max(0, math.floor((w - #label) / 2)), y)
  mon.setTextColor(fg or colors.black)
  mon.write(label)
  mon.setTextColor(colors.white)
  mon.setBackgroundColor(colors.black)
end

-- Case de de en mode COMPACT (repli texte, sans sous-pixel) : un
-- simple carre colore avec le chiffre dedans -- utilise si l'ecran
-- est trop petit pour le format detaille.
local function drawDieCompact(mon, x, y, value)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(colors.white)
  mon.setTextColor(colors.black)
  mon.write(" " .. tostring(value) .. " ")
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

local function drawEmptySlotCompact(mon, x, y)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  mon.write("[ ]")
  mon.setTextColor(colors.white)
end

local function drawEmptySlotFull(mon, x, y, cellW, cellH)
  for row = 0, cellH - 1 do
    mon.setCursorPos(x, y + row)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.gray)
    mon.write(string.rep("-", cellW))
  end
  mon.setTextColor(colors.white)
end

-- Parametres (largeur/hauteur en caracteres, taille de l'icone en
-- pixels sous-pixel, et si on utilise le sous-pixel du tout) pour
-- chaque "tier" de rendu de grille.
local GRID_TIERS = {
  compact = { cellW = 3, cellH = 1, gap = 0, subpixel = false },
  full    = { cellW = DIE_CHAR_W, cellH = DIE_CHAR_H, gap = 1, subpixel = true, pixW = DIE_PIX_W, pixH = DIE_PIX_H },
  big     = { cellW = SHARED_DIE_CHAR_W, cellH = SHARED_DIE_CHAR_H, gap = 1, subpixel = true,
              pixW = SHARED_DIE_PIX_W, pixH = SHARED_DIE_PIX_H },
}

-- Dessine une grille complete (3x3) a partir de (x,y). `tier` =
-- "compact" | "full" | "big" (voir GRID_TIERS). Si `clickCols` est
-- fourni (liste de bool par colonne), retourne les zones cliquables
-- pour les colonnes autorisees (couvrant toute la hauteur de la
-- grille).
local function drawGrid(mon, x, y, grid, tier, clickCols)
  local t = GRID_TIERS[tier]
  local cellW, cellH, gap = t.cellW, t.cellH, t.gap
  local slotW, slotH = cellW + gap, cellH + gap
  local zones = {}

  for col = 1, COLS do
    local colX = x + (col - 1) * slotW
    for row = 1, ROWS do
      -- row 1 = bas de la colonne (voir representation du moteur) :
      -- on l'affiche donc en BAS visuellement, row ROWS en haut.
      local visualRow = ROWS - row + 1
      local cellY = y + (visualRow - 1) * slotH
      local value = grid[col][row]
      if value then
        if t.subpixel then subpixel.draw(mon, colX, cellY, buildDieIcon(value, t.pixW, t.pixH), t.pixW, t.pixH)
        else drawDieCompact(mon, colX, cellY, value) end
      else
        if t.subpixel then drawEmptySlotFull(mon, colX, cellY, cellW, cellH)
        else drawEmptySlotCompact(mon, colX, cellY) end
      end
    end

    -- score de la colonne, juste en dessous
    local scoreY = y + ROWS * slotH
    mon.setCursorPos(colX, scoreY)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.yellow)
    mon.write(tostring(scoreColumn(grid[col])))
    mon.setTextColor(colors.white)

    if clickCols and clickCols[col] then
      zones[#zones + 1] = {
        x1 = colX, y1 = y, x2 = colX + cellW - 1, y2 = scoreY, action = "place", col = col,
      }
    end
  end

  local totalHeight = ROWS * slotH + 1 -- +1 pour la ligne de scores
  local totalWidth = COLS * slotW - gap
  return zones, totalWidth, totalHeight
end

-- Determine si le format detaille (sous-pixel) tient dans la
-- hauteur/largeur disponible pour l'ecran mural (de courant + UNE
-- seule grille, la sienne -- plus de grille adverse sur cet ecran).
local function chooseTierForWall(w, h)
  local fullGridW = COLS * (DIE_CHAR_W + 1) - 1
  local fullGridH = ROWS * (DIE_CHAR_H + 1) + 1
  -- entete (3 lignes) + de courant (DIE_CHAR_H+2 lignes) + 1 grille
  local neededH = 3 + (DIE_CHAR_H + 2) + fullGridH
  if fullGridW <= w and neededH <= h then return "full" end
  return "compact"
end

-- ------------------------------------------------------------
-- Ecran MURAL (par joueur) : uniquement TON de courant + TA grille
-- (cliquable si c'est ton tour) -- plus de grille adverse ici, elle
-- est desormais reservee a l'ecran partage.
-- ------------------------------------------------------------
local function renderWall(G, mon, side)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}
  local opponent = otherSide(side)
  local myTurn = (not G.gameOver) and G.currentPlayer == side
  local tier = chooseTierForWall(w, h)

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  if G.gameOver then
    if G.winner == "draw" then
      mon.write("Match nul !")
    elseif G.winner == side then
      mon.setTextColor(colors.lime)
      mon.write("Tu as gagne !")
    else
      mon.setTextColor(colors.red)
      mon.write("L'adversaire a gagne...")
    end
  elseif myTurn then
    mon.setTextColor(colors.lime)
    mon.write("A toi de jouer !")
  else
    mon.setTextColor(colors.lightGray)
    mon.write("Tour de l'adversaire...")
  end
  mon.setTextColor(colors.white)

  mon.setCursorPos(1, 2)
  mon.write(string.format("Toi: %d   Adversaire: %d", scoreGrid(G.grids[side]), scoreGrid(G.grids[opponent])))

  local y = 4

  if G.gameOver then
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, y, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = y, x2 = btnW, y2 = y, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, y, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = y, x2 = quitX + btnW - 1, y2 = y, action = "quit" }
    return clickZones
  end

  -- de courant (celui du joueur dont c'est le tour -- transparent,
  -- pas d'info cachee dans ce jeu)
  mon.setCursorPos(1, y)
  mon.setTextColor(colors.lightGray)
  mon.write(myTurn and "Ton de :" or "De de l'adversaire :")
  mon.setTextColor(colors.white)
  y = y + 1
  if tier == "compact" then
    drawDieCompact(mon, 1, y, G.currentRoll)
    y = y + 2
  else
    subpixel.draw(mon, 1, y, buildDieIcon(G.currentRoll, DIE_PIX_W, DIE_PIX_H), DIE_PIX_W, DIE_PIX_H)
    y = y + DIE_CHAR_H + 1
  end

  mon.setCursorPos(1, y)
  mon.setTextColor(colors.lightGray)
  mon.write("Ta grille :")
  mon.setTextColor(colors.white)
  y = y + 1
  local clickCols = nil
  if myTurn then
    clickCols = {}
    for col = 1, COLS do clickCols[col] = not isColumnFull(G.grids[side][col]) end
  end
  local myZones = drawGrid(mon, 1, y, G.grids[side], tier, clickCols)
  for _, z in ipairs(myZones) do clickZones[#clickZones + 1] = z end

  return clickZones
end

-- ------------------------------------------------------------
-- Ecran PARTAGE : les 2 grilles cote a cote a l'horizontale, en TRES
-- GROS (taille "big", dediee a ce grand ecran) -- vue d'ensemble
-- non-interactive.
-- ------------------------------------------------------------
local function renderShared(G)
  local w, h = shared.getSize()
  shared.setBackgroundColor(colors.black)
  shared.clear()

  shared.setCursorPos(1, 1)
  shared.setTextColor(colors.white)
  if G.gameOver then
    if G.winner == "draw" then
      shared.write("Match nul !")
    else
      shared.setTextColor(colors.lime)
      shared.write(SIDE_LABEL[G.winner] .. " a gagne !")
    end
  else
    shared.setTextColor(colors.lime)
    shared.write("Tour de " .. SIDE_LABEL[G.currentPlayer] .. " -- de courant: " .. tostring(G.currentRoll))
  end
  shared.setTextColor(colors.white)

  -- essaie le format "big" (bien plus gros que le mur) ; ne bascule
  -- en "full" (taille mur) que si "big" ne tient vraiment pas, et en
  -- dernier recours en "compact".
  local bigGridW = COLS * (SHARED_DIE_CHAR_W + 1) - 1
  local bigGridH = ROWS * (SHARED_DIE_CHAR_H + 1) + 1
  local colGap = 4
  local tier
  if 2 * bigGridW + colGap <= w and bigGridH + 2 <= h then
    tier = "big"
  elseif chooseTierForWall(math.floor((w - colGap) / 2), h - 2) == "full" then
    tier = "full"
  else
    tier = "compact"
  end

  local cellW = GRID_TIERS[tier].cellW
  local halfW = COLS * (cellW + 1) - 1

  local y = 3
  shared.setCursorPos(1, y)
  shared.setTextColor(colors.lightGray)
  shared.write(SIDE_LABEL.player1 .. " (score: " .. scoreGrid(G.grids.player1) .. ")")
  local x2 = 1 + halfW + colGap
  shared.setCursorPos(x2, y)
  shared.write(SIDE_LABEL.player2 .. " (score: " .. scoreGrid(G.grids.player2) .. ")")
  shared.setTextColor(colors.white)

  y = y + 1
  drawGrid(shared, 1, y, G.grids.player1, tier, nil)
  drawGrid(shared, x2, y, G.grids.player2, tier, nil)
end

local lastClickZones = { player1 = {}, player2 = {} }
_G.__KB_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

local function redrawAll(G)
  for _, key in ipairs(SCREEN_KEYS) do
    local s = SCREENS[key]
    lastClickZones[key] = renderWall(G, s.mon, s.side)
  end
  renderShared(G)
end

local function zoneAt(zones, x, y)
  for _, z in ipairs(zones) do
    if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z end
  end
  return nil
end

local function zoneToAction(zone)
  if zone.action == "place" then return { type = "place", col = zone.col } end
  if zone.action == "restart" then return { type = "restart" } end
  if zone.action == "quit" then return { type = "quit" } end
  return nil
end

local function handleAction(G, side, action)
  if action.type == "place" then
    placeDie(G, side, action.col)
    return G, false
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Knucklebones (2 joueurs) lance. Ctrl+T pour arreter.")

if _G.__KB_AUTOPILOT then
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__KB_AUTOPILOT_GAMES do
    local key, zones
    for _, candidate in ipairs(SCREEN_KEYS) do
      if #lastClickZones[candidate] > 0 then
        key, zones = candidate, lastClickZones[candidate]
        break
      end
    end
    if not key then
      error("Aucune zone cliquable -- deadlock UI possible")
    end
    local chosen = zones[math.random(#zones)]
    local action = zoneToAction(chosen)
    if action then
      G = handleAction(G, SCREENS[key].side, action)
      redrawAll(G)
      totalTurns = totalTurns + 1
      if chosen.action == "restart" then gamesPlayed = gamesPlayed + 1 end
    end
    if totalTurns > _G.__KB_AUTOPILOT_GAMES * 2000 then
      error("Autopilot: trop de tours sans terminer assez de parties (deadlock probable)")
    end
  end
  print(string.format("AUTOPILOT OK: %d parties, %d actions UI totales", gamesPlayed, totalTurns))
  return
end

while true do
  local event, side, x, y = os.pullEvent("monitor_touch")
  local key = NAME_TO_KEY[side]
  if key then
    local zone = zoneAt(lastClickZones[key], x, y)
    if zone then
      local action = zoneToAction(zone)
      if action then
        local quit
        G, quit = handleAction(G, SCREENS[key].side, action)
        if quit then
          for _, k in ipairs(SCREEN_KEYS) do
            local mon = SCREENS[k].mon
            mon.setBackgroundColor(colors.black)
            mon.clear()
          end
          shared.setBackgroundColor(colors.black)
          shared.clear()
          print("Knucklebones ferme.")
          return
        end
        redrawAll(G)
      end
    end
  end
end