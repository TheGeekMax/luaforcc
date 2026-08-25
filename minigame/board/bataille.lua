--[[
  battleship_game.lua
  ---------------------------------------------------------------
  luaforcc :: Bataille navale, 2 joueurs, 2 moniteurs PRIVES (comme
  Uno -- si les 2 moniteurs sont physiquement separes, chaque joueur
  ne voit jamais la flotte de l'autre).

  Grille 10x10, flotte standard : porte-avions(5), cuirasse(4),
  croiseur(3), sous-marin(3), torpilleur(2). Placement ALEATOIRE
  automatique au lancement (pas de placement manuel).

  Chaque joueur peut basculer a tout moment entre 2 vues sur son
  propre ecran :
    - "Ma flotte"  : ses bateaux + les tirs recus (touches/coules)
    - "Mes tirs"   : sa grille de tir sur l'ennemi (touche/rate) --
                     c'est LA SEULE vue ou on peut tirer, et
                     seulement si c'est son tour.

  Rendu compact (cellules 2 caracteres de large x 1 de haut, pas de
  pixel art) pour rester jouable meme sur un petit moniteur en
  scale 0.5 -- une grille 10x10 en pixel art 4x4 serait bien trop
  large.

  Regle assumee : le tour passe toujours a l'autre joueur, touche
  ou rate (pas de "rejoue si touche" -- simplification pour rester
  simple ; a changer facilement si tu veux la variante "rejoue si
  touche").

  Config moniteurs chargee depuis monitors.cfg via monitors.lua.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 0.5
local SIZE = 10 -- grille SIZE x SIZE

local SHIPS = {
  { name = "Porte-avions", len = 5 },
  { name = "Cuirasse",     len = 4 },
  { name = "Croiseur",     len = 3 },
  { name = "Sous-marin",   len = 3 },
  { name = "Torpilleur",   len = 2 },
}

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

local function emptyGrid(fill)
  local g = {}
  for r = 1, SIZE do
    g[r] = {}
    for c = 1, SIZE do g[r][c] = fill end
  end
  return g
end

local function inBounds(r, c)
  return r >= 1 and r <= SIZE and c >= 1 and c <= SIZE
end

-- Place aleatoirement tous les SHIPS sur une grille vide. Retourne
-- (fleetGrid, shipCells) : fleetGrid[r][c] = 0 ou index de bateau
-- (dans SHIPS) ; shipCells[shipIdx] = liste de {r=,c=}.
local function placeFleetRandomly()
  local grid = emptyGrid(0)
  local shipCells = {}

  for shipIdx, ship in ipairs(SHIPS) do
    local placed = false
    local attempts = 0
    while not placed and attempts < 500 do
      attempts = attempts + 1
      local horizontal = math.random(2) == 1
      local r = math.random(SIZE)
      local c = math.random(SIZE)
      local cells = {}
      local ok = true
      for k = 0, ship.len - 1 do
        local rr = horizontal and r or (r + k)
        local cc = horizontal and (c + k) or c
        if not inBounds(rr, cc) or grid[rr][cc] ~= 0 then
          ok = false
          break
        end
        cells[#cells + 1] = { r = rr, c = cc }
      end
      if ok then
        for _, cell in ipairs(cells) do grid[cell.r][cell.c] = shipIdx end
        shipCells[shipIdx] = cells
        placed = true
      end
    end
    if not placed then
      error("placeFleetRandomly: impossible de placer " .. ship.name .. " (ne devrait pas arriver)")
    end
  end

  return grid, shipCells
end

local function totalShipCells()
  local n = 0
  for _, s in ipairs(SHIPS) do n = n + s.len end
  return n
end

local function newGame()
  local fleet1, ships1 = placeFleetRandomly()
  local fleet2, ships2 = placeFleetRandomly()

  return {
    fleet = { fleet1, fleet2 },       -- fleet[p][r][c] = 0 ou index de bateau
    shipCells = { ships1, ships2 },   -- shipCells[p][shipIdx] = {{r,c},...}
    shipHits = { {}, {} },            -- shipHits[p][shipIdx] = nb de touches
    sunk = { {}, {} },                -- sunk[p][shipIdx] = true/false
    incoming = { emptyGrid(nil), emptyGrid(nil) }, -- tirs RECUS par p ("hit"/"miss"/nil)
    outgoing = { emptyGrid(nil), emptyGrid(nil) }, -- tirs TIRES par p ("hit"/"miss"/nil)
    shipsRemaining = { #SHIPS, #SHIPS },
    currentPlayer = 1,
    gameOver = false,
    winner = nil,
    view = { "attack", "attack" }, -- vue actuelle de chaque joueur : "fleet" ou "attack"
  }
end

local function otherPlayer(p) return (p == 1) and 2 or 1 end

-- Tire en (r,c) sur la grille de l'ADVERSAIRE de `playerIndex`.
local function fireShot(G, playerIndex, r, c)
  if G.gameOver then return false end
  if G.currentPlayer ~= playerIndex then return false end
  if not inBounds(r, c) then return false end
  if G.outgoing[playerIndex][r][c] ~= nil then return false end -- deja tire ici

  local opponent = otherPlayer(playerIndex)
  local shipIdx = G.fleet[opponent][r][c]

  if shipIdx ~= 0 then
    G.outgoing[playerIndex][r][c] = "hit"
    G.incoming[opponent][r][c] = "hit"
    G.shipHits[opponent][shipIdx] = (G.shipHits[opponent][shipIdx] or 0) + 1
    if G.shipHits[opponent][shipIdx] >= SHIPS[shipIdx].len and not G.sunk[opponent][shipIdx] then
      G.sunk[opponent][shipIdx] = true
      G.shipsRemaining[opponent] = G.shipsRemaining[opponent] - 1
      if G.shipsRemaining[opponent] <= 0 then
        G.gameOver = true
        G.winner = playerIndex
      end
    end
  else
    G.outgoing[playerIndex][r][c] = "miss"
    G.incoming[opponent][r][c] = "miss"
  end

  if not G.gameOver then
    G.currentPlayer = opponent
  end

  return true
end

local function setView(G, playerIndex, view)
  if view ~= "fleet" and view ~= "attack" then return false end
  G.view[playerIndex] = view
  return true
end

local function isShipSunkAt(G, playerIndex, r, c)
  local shipIdx = G.fleet[playerIndex][r][c]
  if shipIdx == 0 then return false end
  return G.sunk[playerIndex][shipIdx] or false
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, playerIndex, action)
  if action.type == "fire" then
    fireShot(G, playerIndex, action.r, action.c)
    return G, false
  elseif action.type == "toggleView" then
    setView(G, playerIndex, action.view)
    return G, false
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

_G.__bs_internal = {
  newGame = newGame,
  fireShot = fireShot,
  setView = setView,
  isShipSunkAt = isShipSunkAt,
  placeFleetRandomly = placeFleetRandomly,
  totalShipCells = totalShipCells,
  handleAction = handleAction,
  SIZE = SIZE,
  SHIPS = SHIPS,
}

if _G.__BS_TEST_MODE then return end

-- ============================================================
-- A PARTIR D'ICI : peripheriques, rendu, boucle de jeu
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

local monitorsLib = dofile(resolveNear("monitors.lua"))
local monitorCfg = monitorsLib.load(resolveNear(MONITORS_CONFIG_PATH))
local MONITOR_1_NAME = monitorCfg.player1
local MONITOR_2_NAME = monitorCfg.player2

local mon1 = peripheral.wrap(MONITOR_1_NAME)
local mon2 = peripheral.wrap(MONITOR_2_NAME)
if not mon1 or not mon2 then
  error("Moniteurs introuvables : verifie '" .. MONITOR_1_NAME .. "' et '" .. MONITOR_2_NAME ..
    "' (definis dans " .. MONITORS_CONFIG_PATH .. ")")
end

mon1.setTextScale(TEXT_SCALE)
mon2.setTextScale(TEXT_SCALE)
local monitors = { mon1, mon2 }

-- ------------------------------------------------------------
-- Rendu : cellules compactes (texte, pas de pixel art -- une
-- grille 10x10 en 4x4 serait bien trop large pour un petit
-- moniteur en scale 0.5).
-- ------------------------------------------------------------

local COLOR_WATER = colors.blue
local COLOR_SHIP = colors.gray
local COLOR_HIT = colors.red
local COLOR_SUNK = colors.black
local COLOR_MISS = colors.lightBlue

local COLUMN_LETTERS = "ABCDEFGHIJ"

-- Paliers d'affichage (du plus lisible au plus compact) : largeur de
-- cellule, contours "[ ]" pour les cases pas encore utilisees, et
-- coordonnees (lettres de colonne + numeros de ligne) ou non.
local DISPLAY_TIERS = {
  { cw = 3, brackets = true,  labels = true },
  { cw = 2, brackets = false, labels = true },
  { cw = 2, brackets = false, labels = false },
  { cw = 1, brackets = false, labels = false },
}

local function rowLabelWidth(tier)
  return tier.labels and 3 or 0 -- "10 " -- 2 chiffres + 1 espace
end

local function computeDisplay(w, h)
  for _, tier in ipairs(DISPLAY_TIERS) do
    local labelW = rowLabelWidth(tier)
    local neededW = labelW + SIZE * tier.cw
    local neededH = (tier.labels and 1 or 0) + SIZE -- ligne d'en-tete colonnes + grille
    if neededW <= w and neededH <= h then
      return tier
    end
  end
  return DISPLAY_TIERS[#DISPLAY_TIERS]
end

-- Case vide/pas-encore-tiree : contour "[ ]" plutot qu'un aplat de
-- couleur, pour bien distinguer les cases entre elles. Toute case
-- avec un contenu (bateau/touche/rate/coule) reste en aplat de
-- couleur avec un symbole -- ca donne "case vide = contour, case
-- avec quelque chose dedans = couleur pleine".
local function drawCell(mon, x, y, tier, bg, label, isEmpty, fg)
  mon.setCursorPos(x, y)
  if isEmpty and tier.brackets then
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lightGray)
    mon.write("[" .. (label or " ") .. "]")
  elseif isEmpty then
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lightGray)
    if tier.cw >= 2 then
      mon.write("." .. string.rep(" ", tier.cw - 1))
    else
      mon.write(".")
    end
  else
    mon.setBackgroundColor(bg)
    mon.setTextColor(fg or colors.white)
    if tier.cw >= 2 then
      mon.write(string.rep(" ", tier.cw - 1) .. (label or " "))
    else
      mon.write(label or " ")
    end
  end
  mon.setTextColor(colors.white)
end

local function drawButton(mon, x, y, w, label, bg, fg)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg or colors.lightGray)
  mon.write(string.rep(" ", w))
  mon.setCursorPos(x + math.max(0, math.floor((w - #label) / 2)), y)
  mon.setTextColor(fg or colors.black)
  mon.write(label)
  mon.setTextColor(colors.white)
end

-- ------------------------------------------------------------
-- Rendu complet d'un ecran pour le joueur `playerIndex`.
-- Retourne les zones cliquables.
-- ------------------------------------------------------------
local function renderScreen(G, mon, playerIndex)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  local tier = computeDisplay(w, h)
  local labelW = rowLabelWidth(tier)
  local gridPixW = labelW + SIZE * tier.cw
  local originX = math.max(1, math.floor((w - gridPixW) / 2) + 1) + labelW

  local headerY = 1
  local toggleY = 2
  local colHeaderY = 3
  local gridY = tier.labels and 4 or 3
  local myTurn = (not G.gameOver) and G.currentPlayer == playerIndex
  local view = G.view[playerIndex]

  -- entete
  mon.setCursorPos(1, headerY)
  mon.setBackgroundColor(colors.black)
  if G.gameOver then
    if G.winner == playerIndex then
      mon.setTextColor(colors.lime)
      mon.write("Victoire !")
    else
      mon.setTextColor(colors.red)
      mon.write("Defaite...")
    end
  elseif myTurn then
    mon.setTextColor(colors.lime)
    mon.write("A toi de tirer !")
  else
    mon.setTextColor(colors.lightGray)
    mon.write("Tour de l'adversaire...")
  end
  mon.setTextColor(colors.white)

  -- bouton bascule de vue (uniquement en cours de partie) ou
  -- boutons de fin de partie -- places IMMEDIATEMENT sous l'entete,
  -- jamais sous la grille : sur un petit ecran, en dependre aurait
  -- pu les faire sortir du cadre et bloquer completement la partie.
  if G.gameOver then
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, toggleY, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = toggleY, x2 = btnW, y2 = toggleY, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, toggleY, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = toggleY, x2 = quitX + btnW - 1, y2 = toggleY, action = "quit" }
  else
    local label = (view == "attack") and "Voir: Mes tirs [<->]" or "Voir: Ma flotte [<->]"
    drawButton(mon, 1, toggleY, math.min(w, 24), label, colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = {
      x1 = 1, y1 = toggleY, x2 = math.min(w, 24), y2 = toggleY,
      action = "toggleView", view = (view == "attack") and "fleet" or "attack",
    }
  end

  -- en-tete de colonnes (lettres) + labels de ligne (numeros)
  if tier.labels then
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lightGray)
    for c = 1, SIZE do
      local x = originX + (c - 1) * tier.cw
      mon.setCursorPos(x + math.floor((tier.cw - 1) / 2), colHeaderY)
      mon.write(COLUMN_LETTERS:sub(c, c))
    end
  end

  -- grille
  for r = 1, SIZE do
    if tier.labels then
      mon.setCursorPos(originX - labelW, gridY + (r - 1))
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(colors.lightGray)
      mon.write(string.format("%2d ", r))
    end

    for c = 1, SIZE do
      local x = originX + (c - 1) * tier.cw
      local y = gridY + (r - 1)
      local bg, label, isEmpty = COLOR_WATER, nil, true

      if view == "fleet" then
        local hasShip = G.fleet[playerIndex][r][c] ~= 0
        local shot = G.incoming[playerIndex][r][c]
        if shot == "hit" then
          bg = isShipSunkAt(G, playerIndex, r, c) and COLOR_SUNK or COLOR_HIT
          label, isEmpty = "X", false
        elseif shot == "miss" then
          bg, label, isEmpty = COLOR_MISS, "o", false
        elseif hasShip then
          bg, isEmpty = COLOR_SHIP, false
        end
      else -- "attack"
        local shot = G.outgoing[playerIndex][r][c]
        if shot == "hit" then
          bg = isShipSunkAt(G, otherPlayer(playerIndex), r, c) and COLOR_SUNK or COLOR_HIT
          label, isEmpty = "X", false
        elseif shot == "miss" then
          bg, label, isEmpty = COLOR_MISS, "o", false
        end
      end

      drawCell(mon, x, y, tier, bg, label, isEmpty)

      if view == "attack" and myTurn and G.outgoing[playerIndex][r][c] == nil then
        clickZones[#clickZones + 1] = {
          x1 = x, y1 = y, x2 = x + tier.cw - 1, y2 = y, action = "fire", r = r, c = c,
        }
      end
    end
  end
  mon.setBackgroundColor(colors.black)

  -- statut flotte (informatif seulement, peut sortir du cadre sur
  -- un tres petit ecran sans consequence fonctionnelle)
  local statusY = gridY + SIZE + 1
  mon.setCursorPos(1, statusY)
  mon.setTextColor(colors.lightGray)
  if statusY <= h then
    mon.write("Tes bateaux restants: " .. G.shipsRemaining[playerIndex] .. "/" .. #SHIPS)
  end
  mon.setTextColor(colors.white)

  return clickZones
end

local lastClickZones = { {}, {} }
_G.__BS_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

local function redrawAll(G)
  lastClickZones[1] = renderScreen(G, mon1, 1)
  lastClickZones[2] = renderScreen(G, mon2, 2)
end

local function zoneAt(zones, x, y)
  for _, z in ipairs(zones) do
    if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z end
  end
  return nil
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Bataille navale lancee sur " .. MONITOR_1_NAME .. " / " .. MONITOR_2_NAME .. ". Ctrl+T pour arreter.")

if _G.__BS_AUTOPILOT then
  -- Mode de test : joue des parties completes via le VRAI pipeline
  -- (rendu -> zones cliquables -> action), sans jamais passer par
  -- os.pullEvent.
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__BS_AUTOPILOT_GAMES do
    -- choisit un ecran au hasard, mais ne fait que ce que CET ecran
    -- autorise reellement (respecte l'isolation par joueur)
    local monIdx = math.random(2)
    local zones = lastClickZones[monIdx]
    if #zones == 0 then
      error("Aucune zone cliquable sur l'ecran " .. monIdx .. " -- deadlock UI possible")
    end
    local chosen = zones[math.random(#zones)]
    local action
    if chosen.action == "fire" then
      action = { type = "fire", r = chosen.r, c = chosen.c }
    elseif chosen.action == "toggleView" then
      action = { type = "toggleView", view = chosen.view }
    elseif chosen.action == "restart" then
      action = { type = "restart" }
    end
    if action then
      G = handleAction(G, monIdx, action)
      redrawAll(G)
      totalTurns = totalTurns + 1
      if chosen.action == "restart" then gamesPlayed = gamesPlayed + 1 end
    end
    if totalTurns > _G.__BS_AUTOPILOT_GAMES * 6000 then
      error("Autopilot: trop de tours sans terminer assez de parties (deadlock probable)")
    end
  end
  print(string.format("AUTOPILOT OK: %d parties, %d actions UI totales", gamesPlayed, totalTurns))
  return
end

while true do
  local event, side, x, y = os.pullEvent("monitor_touch")
  local monIdx = (side == MONITOR_1_NAME) and 1 or (side == MONITOR_2_NAME) and 2 or nil
  if monIdx then
    local zone = zoneAt(lastClickZones[monIdx], x, y)
    if zone then
      local action
      if zone.action == "fire" then
        action = { type = "fire", r = zone.r, c = zone.c }
      elseif zone.action == "toggleView" then
        action = { type = "toggleView", view = zone.view }
      elseif zone.action == "restart" then
        action = { type = "restart" }
      elseif zone.action == "quit" then
        action = { type = "quit" }
      end
      if action then
        local quit
        G, quit = handleAction(G, monIdx, action)
        if quit then
          mon1.setBackgroundColor(colors.black)
          mon1.clear()
          mon2.setBackgroundColor(colors.black)
          mon2.clear()
          print("Bataille navale fermee.")
          return
        end
        redrawAll(G)
      end
    end
  end
end