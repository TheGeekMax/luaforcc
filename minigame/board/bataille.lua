--[[
  battleship_game.lua
  ---------------------------------------------------------------
  luaforcc :: Bataille navale, 2 joueurs, 4 moniteurs PRIVES (2 par
  joueur -- si les ecrans d'un joueur sont physiquement separes de
  ceux de l'autre, chacun ne voit jamais la flotte de l'autre).

  Grille 10x10, flotte standard : porte-avions(5), cuirasse(4),
  croiseur(3), sous-marin(3), torpilleur(2). Placement ALEATOIRE
  automatique au lancement (pas de placement manuel).

  Chaque joueur a 2 ecrans DEDIES (plus de bouton pour basculer) :
    - ecran MURAL (monitors.cfg ligne 1/2) : "Mes tirs" -- sa grille
      de tir sur l'ennemi (touche/rate). C'est LA SEULE ou on peut
      tirer, et seulement si c'est son tour.
    - ecran AU SOL (monitors.cfg ligne 4/5, floor1/floor2) :
      "Mes bateaux" -- sa propre flotte + les tirs recus.

  Rendu compact (cellules texte, pas de pixel art) pour rester
  jouable meme sur un petit moniteur en scale 0.5 -- une grille
  10x10 en pixel art 4x4 serait bien trop large.

  Regle assumee : le tour passe toujours a l'autre joueur, touche
  ou rate (pas de "rejoue si touche" -- simplification pour rester
  simple ; a changer facilement si tu veux la variante "rejoue si
  touche").

  Config moniteurs chargee depuis monitors.cfg via monitors.lua.
  Ce jeu EXIGE les ecrans au sol (floor1/floor2) -- voir
  monitors.requireFloors().
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
monitorsLib.requireFloors(monitorCfg) -- ce jeu a besoin des 2 ecrans au sol

local WALL_1_NAME = monitorCfg.player1
local WALL_2_NAME = monitorCfg.player2
local FLOOR_1_NAME = monitorCfg.floor1
local FLOOR_2_NAME = monitorCfg.floor2

local wall1 = peripheral.wrap(WALL_1_NAME)
local wall2 = peripheral.wrap(WALL_2_NAME)
local floor1 = peripheral.wrap(FLOOR_1_NAME)
local floor2 = peripheral.wrap(FLOOR_2_NAME)

for _, entry in ipairs({
  { WALL_1_NAME, wall1 }, { WALL_2_NAME, wall2 },
  { FLOOR_1_NAME, floor1 }, { FLOOR_2_NAME, floor2 },
}) do
  if not entry[2] then
    error("Moniteur introuvable : '" .. entry[1] .. "' (defini dans " .. MONITORS_CONFIG_PATH .. ")")
  end
end

wall1.setTextScale(TEXT_SCALE)
wall2.setTextScale(TEXT_SCALE)
floor1.setTextScale(TEXT_SCALE)
floor2.setTextScale(TEXT_SCALE)

-- Table des 4 ecrans : cle -> { mon=, player=, mode= }. mode="attack"
-- (ecran mural, "Mes tirs") ou "fleet" (ecran au sol, "Mes bateaux").
local SCREENS = {
  wall1  = { mon = wall1,  player = 1, mode = "attack" },
  floor1 = { mon = floor1, player = 1, mode = "fleet" },
  wall2  = { mon = wall2,  player = 2, mode = "attack" },
  floor2 = { mon = floor2, player = 2, mode = "fleet" },
}
local SCREEN_KEYS = { "wall1", "floor1", "wall2", "floor2" }

-- nom de moniteur -> cle d'ecran, pour router les touch events
local NAME_TO_KEY = {
  [WALL_1_NAME] = "wall1", [FLOOR_1_NAME] = "floor1",
  [WALL_2_NAME] = "wall2", [FLOOR_2_NAME] = "floor2",
}

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
      local leftPad = math.floor((tier.cw - 1) / 2)
      local rightPad = (tier.cw - 1) - leftPad
      mon.write(string.rep(" ", leftPad) .. (label or " ") .. string.rep(" ", rightPad))
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
-- Rendu complet d'un ecran. `mode` = "attack" (ecran mural, grille
-- de tir) ou "fleet" (ecran au sol, propre flotte). Retourne les
-- zones cliquables.
-- ------------------------------------------------------------
local function renderScreen(G, mon, playerIndex, mode, yOffset)
  yOffset = yOffset or 0
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  local tier = computeDisplay(w, h - yOffset)
  local labelW = rowLabelWidth(tier)
  local gridPixW = labelW + SIZE * tier.cw
  local originX = math.max(1, math.floor((w - gridPixW) / 2) + 1) + labelW

  local headerY = 1 + yOffset
  local colHeaderY = 2 + yOffset
  local gridY = (tier.labels and 3 or 2) + yOffset
  local myTurn = (not G.gameOver) and G.currentPlayer == playerIndex

  -- entete : statut de partie + rappel du role de cet ecran
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
  elseif mode == "fleet" then
    mon.setTextColor(colors.lightGray)
    mon.write(myTurn and "Mes bateaux (a toi de tirer)" or "Mes bateaux")
  elseif myTurn then
    mon.setTextColor(colors.lime)
    mon.write("Mes tirs -- a toi de jouer !")
  else
    mon.setTextColor(colors.lightGray)
    mon.write("Mes tirs -- tour adverse...")
  end
  mon.setTextColor(colors.white)

  -- boutons de fin de partie -- places IMMEDIATEMENT sous l'entete,
  -- jamais sous la grille : sur un petit ecran, en dependre aurait
  -- pu les faire sortir du cadre et bloquer completement la partie.
  -- Disponibles sur les 4 ecrans par simplicite.
  if G.gameOver then
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, colHeaderY, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = colHeaderY, x2 = btnW, y2 = colHeaderY, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, colHeaderY, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = colHeaderY, x2 = quitX + btnW - 1, y2 = colHeaderY, action = "quit" }
    gridY = colHeaderY + (tier.labels and 2 or 1)
  end

  -- en-tete de colonnes (lettres) + labels de ligne (numeros)
  if tier.labels then
    local chY = G.gameOver and (gridY - 1) or colHeaderY
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lightGray)
    for c = 1, SIZE do
      local x = originX + (c - 1) * tier.cw
      mon.setCursorPos(x + math.floor((tier.cw - 1) / 2), chY)
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

      if mode == "fleet" then
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

      if mode == "attack" and myTurn and G.outgoing[playerIndex][r][c] == nil then
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
    mon.write("Bateaux restants: " .. G.shipsRemaining[playerIndex] .. "/" .. #SHIPS)
  end
  mon.setTextColor(colors.white)

  return clickZones
end

local lastClickZones = { wall1 = {}, floor1 = {}, wall2 = {}, floor2 = {} }
_G.__BS_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

-- Decalage vertical applique uniquement aux ecrans au sol -- purement
-- esthetique (le mur n'a pas besoin de cette marge), pour ne pas
-- coller le contenu tout en haut d'un moniteur pose/incline au sol.
local FLOOR_Y_OFFSET = 5

local function redrawAll(G)
  for _, key in ipairs(SCREEN_KEYS) do
    local s = SCREENS[key]
    local yOffset = (s.mode == "fleet") and FLOOR_Y_OFFSET or 0
    lastClickZones[key] = renderScreen(G, s.mon, s.player, s.mode, yOffset)
  end
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
print("Bataille navale lancee (" .. WALL_1_NAME .. "/" .. FLOOR_1_NAME .. " -- " ..
  WALL_2_NAME .. "/" .. FLOOR_2_NAME .. "). Ctrl+T pour arreter.")

if _G.__BS_AUTOPILOT then
  -- Mode de test : joue des parties completes via le VRAI pipeline
  -- (rendu -> zones cliquables -> action), sans jamais passer par
  -- os.pullEvent.
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__BS_AUTOPILOT_GAMES do
    -- les ecrans au sol sont purement informatifs en cours de partie
    -- (0 zone cliquable, normal) ; on cherche un ecran qui a
    -- reellement quelque chose a proposer, et on ne crie au
    -- deadlock que si AUCUN des 4 n'en a.
    local key, zones
    for _ = 1, #SCREEN_KEYS do
      local candidate = SCREEN_KEYS[math.random(#SCREEN_KEYS)]
      if #lastClickZones[candidate] > 0 then
        key, zones = candidate, lastClickZones[candidate]
        break
      end
    end
    if not key then
      local anyZones = false
      for _, k in ipairs(SCREEN_KEYS) do
        if #lastClickZones[k] > 0 then anyZones = true end
      end
      if not anyZones then
        error("Aucun ecran n'a de zone cliquable -- deadlock UI possible")
      end
      goto continue
    end
    do
      local chosen = zones[math.random(#zones)]
      local action
      if chosen.action == "fire" then
        action = { type = "fire", r = chosen.r, c = chosen.c }
      elseif chosen.action == "restart" then
        action = { type = "restart" }
      end
      if action then
        G = handleAction(G, SCREENS[key].player, action)
        redrawAll(G)
        totalTurns = totalTurns + 1
        if chosen.action == "restart" then gamesPlayed = gamesPlayed + 1 end
      end
    end
    ::continue::
    if totalTurns > _G.__BS_AUTOPILOT_GAMES * 6000 then
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
      local action
      if zone.action == "fire" then
        action = { type = "fire", r = zone.r, c = zone.c }
      elseif zone.action == "restart" then
        action = { type = "restart" }
      elseif zone.action == "quit" then
        action = { type = "quit" }
      end
      if action then
        local quit
        G, quit = handleAction(G, SCREENS[key].player, action)
        if quit then
          for _, k in ipairs(SCREEN_KEYS) do
            local mon = SCREENS[k].mon
            mon.setBackgroundColor(colors.black)
            mon.clear()
          end
          print("Bataille navale fermee.")
          return
        end
        redrawAll(G)
      end
    end
  end
end