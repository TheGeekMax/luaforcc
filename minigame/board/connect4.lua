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
local TEXT_SCALE = 1
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

-- Resout un chemin relatif au dossier du script en cours d'execution
-- (pas au dossier courant du shell, qui peut varier selon d'ou on
-- lance la commande) -- indispensable pour un systeme a plusieurs
-- jeux ranges chacun dans leur propre dossier.
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

local PLAYER_COLORS = { colors.red, colors.yellow }
local PLAYER_NAMES = { "Rouge", "Jaune" }

-- ------------------------------------------------------------
-- Pixel art : jeton (forme arrondie) et case vide. La taille du
-- jeton et l'espacement s'adaptent a la resolution du moniteur
-- (utile pour un petit moniteur, ex. 2x2 blocs) : on choisit le
-- plus grand format qui tient encore verticalement (6 rangees +
-- entete + boutons de fin de partie).
-- ------------------------------------------------------------

local function iconToken(pix, color)
  if pix == 4 then
    return {
      { 0, color, color, 0 },
      { color, color, color, color },
      { color, color, color, color },
      { 0, color, color, 0 },
    }
  end
  -- format compact (3x3)
  return {
    { color, color, color },
    { color, color, color },
    { color, color, color },
  }
end

local function emptyIcon(pix)
  if pix == 4 then
    return {
      { 0, colors.gray, colors.gray, 0 },
      { colors.gray, 0, 0, colors.gray },
      { colors.gray, 0, 0, colors.gray },
      { 0, colors.gray, colors.gray, 0 },
    }
  end
  return {
    { colors.gray, 0, colors.gray },
    { 0, colors.gray, 0 },
    { colors.gray, 0, colors.gray },
  }
end

local function drawPixelCell(mon, x, y, pix, icon, highlight)
  for iy = 1, pix do
    for ix = 1, pix do
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

-- Paliers essayes du plus spacieux au plus compact : {pix, borderX, borderY}.
-- borderY=0 economise beaucoup de hauteur (6 rangees) ; borderX reste a
-- 1 le plus longtemps possible pour que le tap par colonne reste net.
local LAYOUT_TIERS = {
  { pix = 4, bx = 1, by = 1 },
  { pix = 4, bx = 1, by = 0 },
  { pix = 3, bx = 1, by = 0 },
  { pix = 3, bx = 0, by = 0 },
}

-- Espace fixe reserve au-dessus/en-dessous de la grille : 1 ligne
-- d'entete, 1 ligne de fleches, 1 ligne vide + 1 ligne de boutons
-- (reservee meme en cours de partie pour eviter que la mise en page
-- ne "saute" en fin de partie), 1 ligne de legende en bas.
local CHROME_ROWS = 5

local function computeLayout(w, h)
  for _, tier in ipairs(LAYOUT_TIERS) do
    local strideX = tier.pix + tier.bx
    local strideY = tier.pix + tier.by
    local gridW = COLS * strideX - tier.bx
    local gridH = ROWS * strideY - tier.by
    if gridW <= w and gridH + CHROME_ROWS <= h then
      return {
        pix = tier.pix, strideX = strideX, strideY = strideY,
        gridW = gridW, gridH = gridH,
      }
    end
  end
  -- rien ne tient parfaitement : on prend le plus compact quand meme
  local tier = LAYOUT_TIERS[#LAYOUT_TIERS]
  local strideX, strideY = tier.pix + tier.bx, tier.pix + tier.by
  return {
    pix = tier.pix, strideX = strideX, strideY = strideY,
    gridW = COLS * strideX - tier.bx, gridH = ROWS * strideY - tier.by,
  }
end

-- ------------------------------------------------------------
-- Rendu complet d'un ecran. `playerIndex` = le joueur assigne a CET
-- ecran (1 ou 2) : seules les colonnes sont cliquables quand c'est
-- reellement le tour de CE joueur -- meme si la grille affichee est
-- identique sur les 2 moniteurs, seul l'ecran du joueur actif peut
-- declencher un coup. Ca evite qu'un seul joueur ne joue les 2 tours
-- depuis son propre ecran.
-- Retourne les zones cliquables : { {x1,y1,x2,y2, action=...}, ... }
-- ------------------------------------------------------------
local function renderScreen(G, mon, playerIndex)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}
  local myTurn = (not G.gameOver) and G.currentPlayer == playerIndex

  local L = computeLayout(w, h)
  local originX = math.max(1, math.floor((w - L.gridW) / 2) + 1)
  local headerY = 1
  local arrowY = 2
  local gridY = 3

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
  elseif myTurn then
    mon.setTextColor(PLAYER_COLORS[playerIndex])
    mon.write("A toi de jouer, " .. PLAYER_NAMES[playerIndex] .. " !")
  else
    mon.setTextColor(colors.lightGray)
    mon.write("Tour de " .. PLAYER_NAMES[G.currentPlayer] .. "...")
  end
  mon.setTextColor(colors.white)

  if not G.gameOver then
    -- fleches de colonne : cliquables SEULEMENT si c'est le tour de ce joueur
    for c = 1, COLS do
      local x = originX + (c - 1) * L.strideX
      local full = isColumnFull(G, c)
      local active = myTurn and not full
      mon.setCursorPos(x, arrowY)
      mon.setBackgroundColor(colors.black)
      mon.setTextColor(active and PLAYER_COLORS[G.currentPlayer] or colors.gray)
      mon.write(full and " " or "v")
      mon.setTextColor(colors.white)
      if active then
        clickZones[#clickZones + 1] = {
          x1 = x, y1 = arrowY, x2 = x + L.pix - 1, y2 = gridY + L.gridH - 1,
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
      local x = originX + (c - 1) * L.strideX
      local y = gridY + (r - 1) * L.strideY
      local val = G.grid[r][c]
      local icon = (val == 0) and emptyIcon(L.pix) or iconToken(L.pix, PLAYER_COLORS[val])
      local highlight = winSet[r .. ":" .. c] or false
      drawPixelCell(mon, x, y, L.pix, icon, highlight)
    end
  end

  if G.gameOver then
    -- Rejouer/Quitter restent accessibles depuis les 2 ecrans (pas
    -- une question de tour, la partie est finie pour tout le monde).
    local by = gridY + L.gridH + 1
    local btnW = 15
    drawButton(mon, originX, by, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = originX, y1 = by, x2 = originX + btnW - 1, y2 = by, action = "restart" }
    local quitX = originX + btnW + 1
    drawButton(mon, quitX, by, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = by, x2 = quitX + btnW - 1, y2 = by, action = "quit" }
  end

  mon.setCursorPos(1, h)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  mon.write("Tu es " .. PLAYER_NAMES[playerIndex])
  mon.setTextColor(colors.white)

  return clickZones
end

local lastClickZones = { {}, {} }
_G.__C4_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

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
print("Puissance 4 lance sur " .. MONITOR_1_NAME .. " / " .. MONITOR_2_NAME .. " (miroir). Ctrl+T pour arreter.")

if _G.__C4_AUTOPILOT then
  -- Mode de test : joue des parties completes via le VRAI pipeline
  -- (rendu -> zones cliquables -> action), sans jamais passer par
  -- os.pullEvent, pour valider aussi la couche UI/tactile.
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__C4_AUTOPILOT_GAMES do
    -- en cours de partie, seul l'ecran du joueur actif a des zones ;
    -- une fois la partie finie, les 2 ecrans proposent Rejouer/Quitter
    local monIdx = G.gameOver and math.random(2) or G.currentPlayer
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
    G = handleAction(G, monIdx, action)
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
        G, quit = handleAction(G, monIdx, action)
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