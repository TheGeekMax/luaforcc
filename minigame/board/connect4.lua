--[[
  connect4_game.lua
  ---------------------------------------------------------------
  luaforcc :: Puissance 4, 2 moniteurs en miroir (pas d'info secrete
  donc les 2 ecrans affichent exactement la meme grille -- un tap
  sur l'un ou l'autre est accepte indifferemment pour le joueur
  dont c'est le tour).

  Grille standard 7 colonnes x 6 lignes. Jetons en pixel art 4x4
  (meme style que le mini-jeu de puzzle). Config des moniteurs
  chargee depuis monitors.cfg via monitors.lua (voir ce fichier) --
  seules les lignes 1 et 2 (joueur 1 / joueur 2) sont utilisees.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 0.5
local COLS, ROWS = 7, 6

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

local function newGame()
  local grid = {}
  for r = 1, ROWS do
    grid[r] = {}
    for c = 1, COLS do
      grid[r][c] = 0 -- 0 = vide, 1 = joueur 1, 2 = joueur 2
    end
  end
  return {
    grid = grid,
    currentPlayer = 1,
    gameOver = false,
    winner = nil, -- 1, 2, ou nil si match nul
    winningCells = nil, -- liste de {row=,col=} si victoire
    lastMove = nil, -- {row=,col=}
  }
end

-- Trouve la ligne la plus basse libre dans la colonne `col`
-- (ROWS = bas de la grille). Retourne nil si la colonne est pleine.
local function lowestFreeRow(G, col)
  for r = ROWS, 1, -1 do
    if G.grid[r][col] == 0 then return r end
  end
  return nil
end

local function isColumnFull(G, col)
  return G.grid[1][col] ~= 0
end

local DIRECTIONS = {
  { dr = 0, dc = 1 },  -- horizontal
  { dr = 1, dc = 0 },  -- vertical
  { dr = 1, dc = 1 },  -- diagonale \
  { dr = 1, dc = -1 }, -- diagonale /
}

local function inGrid(r, c)
  return r >= 1 and r <= ROWS and c >= 1 and c <= COLS
end

-- Cherche un alignement de 4 passant par (row,col) pour `player`.
-- Retourne la liste des 4 (ou plus) cellules alignees, ou nil.
local function findWinAt(G, row, col, player)
  for _, d in ipairs(DIRECTIONS) do
    local cells = { { row = row, col = col } }
    -- sens positif
    local r, c = row + d.dr, col + d.dc
    while inGrid(r, c) and G.grid[r][c] == player do
      cells[#cells + 1] = { row = r, col = c }
      r, c = r + d.dr, c + d.dc
    end
    -- sens negatif
    r, c = row - d.dr, col - d.dc
    while inGrid(r, c) and G.grid[r][c] == player do
      cells[#cells + 1] = { row = r, col = c }
      r, c = r - d.dr, c - d.dc
    end
    if #cells >= 4 then return cells end
  end
  return nil
end

local function boardFull(G)
  for c = 1, COLS do
    if not isColumnFull(G, c) then return false end
  end
  return true
end

-- Joue dans la colonne `col` pour le joueur courant. Retourne true
-- si le coup a ete joue (false si colonne pleine, partie finie, ou
-- ce n'est pas ce joueur qui joue).
local function dropPiece(G, playerIndex, col)
  if G.gameOver then return false end
  if G.currentPlayer ~= playerIndex then return false end
  if col < 1 or col > COLS then return false end
  local row = lowestFreeRow(G, col)
  if not row then return false end

  G.grid[row][col] = playerIndex
  G.lastMove = { row = row, col = col }

  local winCells = findWinAt(G, row, col, playerIndex)
  if winCells then
    G.gameOver = true
    G.winner = playerIndex
    G.winningCells = winCells
  elseif boardFull(G) then
    G.gameOver = true
    G.winner = nil
  else
    G.currentPlayer = (playerIndex == 1) and 2 or 1
  end

  return true
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, playerIndex, action)
  if action.type == "drop" then
    dropPiece(G, playerIndex, action.col)
    return G, false
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

_G.__c4_internal = {
  newGame = newGame,
  dropPiece = dropPiece,
  findWinAt = findWinAt,
  lowestFreeRow = lowestFreeRow,
  isColumnFull = isColumnFull,
  boardFull = boardFull,
  handleAction = handleAction,
  COLS = COLS,
  ROWS = ROWS,
}

if _G.__C4_TEST_MODE then return end

-- ============================================================
-- A PARTIR D'ICI : peripheriques, rendu, boucle de jeu
-- (non charge en mode test)
-- ============================================================

local monitorsLib = dofile("monitors.lua")
local monitorCfg = monitorsLib.load(MONITORS_CONFIG_PATH)
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

local PLAYER_COLORS = { colors.red, colors.yellow }
local PLAYER_NAMES = { "Rouge", "Jaune" }

-- ------------------------------------------------------------
-- Pixel art : jeton 4x4 (forme arrondie) et case vide
-- ------------------------------------------------------------
local PIX = 4

local function iconToken(color)
  return {
    { 0, color, color, 0 },
    { color, color, color, color },
    { color, color, color, color },
    { 0, color, color, 0 },
  }
end

local EMPTY_ICON = {
  { 0, colors.gray, colors.gray, 0 },
  { colors.gray, 0, 0, colors.gray },
  { colors.gray, 0, 0, colors.gray },
  { 0, colors.gray, colors.gray, 0 },
}

local function drawPixelCell(mon, x, y, icon, highlight)
  for iy = 1, PIX do
    for ix = 1, PIX do
      local color = icon[iy][ix]
      if color == 0 then
        color = highlight and colors.lightGray or colors.black
      end
      mon.setCursorPos(x + ix - 1, y + iy - 1)
      mon.setBackgroundColor(color)
      mon.write(" ")
    end
  end
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

local BORDER = 1
local STRIDE = PIX + BORDER
local GRID_PIX_W = COLS * STRIDE - BORDER
local GRID_PIX_H = ROWS * STRIDE - BORDER

-- ------------------------------------------------------------
-- Rendu complet d'un ecran (identique sur les 2 moniteurs).
-- Retourne les zones cliquables : { {x1,y1,x2,y2, action=...}, ... }
-- ------------------------------------------------------------
local function renderScreen(G, mon)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  local originX = math.max(1, math.floor((w - GRID_PIX_W) / 2) + 1)
  local headerY = 1
  local gridY = 4

  mon.setCursorPos(1, headerY)
  mon.setBackgroundColor(colors.black)
  if G.gameOver then
    if G.winner then
      mon.setTextColor(PLAYER_COLORS[G.winner])
      mon.write(PLAYER_NAMES[G.winner] .. " a gagne !")
    else
      mon.setTextColor(colors.white)
      mon.write("Match nul !")
    end
  else
    mon.setTextColor(PLAYER_COLORS[G.currentPlayer])
    mon.write("Au tour de " .. PLAYER_NAMES[G.currentPlayer])
  end
  mon.setTextColor(colors.white)

  if not G.gameOver then
    -- fleches de colonne cliquables (rangee au-dessus de la grille)
    for c = 1, COLS do
      local x = originX + (c - 1) * STRIDE
      local full = isColumnFull(G, c)
      mon.setCursorPos(x, headerY + 2)
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(full and colors.gray or PLAYER_COLORS[G.currentPlayer])
      mon.write(full and " " or "v")
      mon.setTextColor(colors.white)
      if not full then
        clickZones[#clickZones + 1] = {
          x1 = x, y1 = headerY + 2, x2 = x + PIX - 1, y2 = gridY + GRID_PIX_H - 1,
          action = "drop", col = c,
        }
      end
    end
  end

  -- grille
  local winSet = {}
  if G.winningCells then
    for _, cell in ipairs(G.winningCells) do
      winSet[cell.row .. ":" .. cell.col] = true
    end
  end

  for r = 1, ROWS do
    for c = 1, COLS do
      local x = originX + (c - 1) * STRIDE
      local y = gridY + (r - 1) * STRIDE
      local val = G.grid[r][c]
      local icon = (val == 0) and EMPTY_ICON or iconToken(PLAYER_COLORS[val])
      local highlight = winSet[r .. ":" .. c] or false
      drawPixelCell(mon, x, y, icon, highlight)
    end
  end

  if G.gameOver then
    local by = gridY + GRID_PIX_H + 2
    drawButton(mon, originX, by, 16, "Nouvelle partie", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = originX, y1 = by, x2 = originX + 15, y2 = by, action = "restart" }
    drawButton(mon, originX, by + 2, 16, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = originX, y1 = by + 2, x2 = originX + 15, y2 = by + 2, action = "quit" }
  end

  mon.setCursorPos(1, h)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  mon.write("Rouge = joueur 1, Jaune = joueur 2")
  mon.setTextColor(colors.white)

  return clickZones
end

local lastClickZones = { {}, {} }

local function redrawAll(G)
  lastClickZones[1] = renderScreen(G, mon1)
  lastClickZones[2] = renderScreen(G, mon2)
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
print("Puissance 4 lance sur " .. MONITOR_1_NAME .. " / " .. MONITOR_2_NAME .. " (miroir). Ctrl+T pour arreter.")

if _G.__C4_AUTOPILOT then
  -- Mode de test : joue des parties completes via le VRAI pipeline
  -- (rendu -> zones cliquables -> action), sans jamais passer par
  -- os.pullEvent, pour valider aussi la couche UI/tactile.
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__C4_AUTOPILOT_GAMES do
    local monIdx = math.random(2) -- touche indifferemment l'un ou l'autre moniteur (miroir)
    local zones = lastClickZones[monIdx]
    if #zones == 0 then
      error("Aucune zone cliquable -- deadlock UI")
    end
    local chosen
    if G.gameOver then
      for _, z in ipairs(zones) do
        if z.action == "restart" then chosen = z break end
      end
    else
      chosen = zones[math.random(#zones)]
    end
    local action
    if chosen.action == "drop" then
      action = { type = "drop", col = chosen.col }
    elseif chosen.action == "restart" then
      action = { type = "restart" }
    end
    G = handleAction(G, G.currentPlayer, action)
    redrawAll(G)
    totalTurns = totalTurns + 1
    if chosen.action == "restart" then
      gamesPlayed = gamesPlayed + 1
    end
    if totalTurns > _G.__C4_AUTOPILOT_GAMES * 2000 then
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
      if zone.action == "drop" then
        action = { type = "drop", col = zone.col }
      elseif zone.action == "restart" then
        action = { type = "restart" }
      elseif zone.action == "quit" then
        action = { type = "quit" }
      end
      if action then
        local quit
        G, quit = handleAction(G, G.currentPlayer, action)
        if quit then
          mon1.setBackgroundColor(colors.black)
          mon1.clear()
          mon2.setBackgroundColor(colors.black)
          mon2.clear()
          print("Puissance 4 ferme.")
          return
        end
        redrawAll(G)
      end
    end
  end
end