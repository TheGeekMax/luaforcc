--[[
  mastermind_game.lua
  ---------------------------------------------------------------
  luaforcc :: Mastermind 2 joueurs, 4 moniteurs (mur+sol par joueur,
  comme la bataille navale).

  Classique : 6 couleurs, code de 4 pions, repetitions autorisees,
  10 essais max chacun.

  Deroulement :
    1) PHASE PREPARATION : chaque joueur compose son code secret sur
       son ecran MURAL (independamment, en meme temps). Une fois les
       2 codes valides, la partie commence.
    2) PHASE JEU : chacun a son tour propose un essai de 4 couleurs
       contre le code de l'adversaire, sur son ecran MURAL. Retour
       simple : nombre de pions bien places, nombre de bonnes
       couleurs mal placees. Rien de plus (pas d'indication de QUELLE
       position est juste).

  Ecrans :
    - MUR (monitors.cfg ligne 1/2) : pendant la preparation, la
      composition de ton code secret. Pendant le jeu, TES essais
      contre le code adverse (+ le clavier de couleurs si c'est ton
      tour).
    - SOL (ligne 4/5, floor1/floor2) : les essais de l'ADVERSAIRE
      contre TON code, affiches a cote de ton propre code (que tu
      connais deja) pour suivre sa progression.

  Fin de partie : premier a trouver le code adverse gagne. Si les 2
  epuisent leurs 10 essais sans trouver -> match nul. Si un seul les
  epuise, l'autre continue normalement (il gagne s'il trouve, sinon
  match nul si lui aussi finit par epuiser ses essais).
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 1
local CODE_LENGTH = 4
local MAX_GUESSES = 10

-- ============================================================
-- DONNEES : couleurs
-- ============================================================

local COLOR_NAMES = { "Rouge", "Orange", "Jaune", "Vert", "Bleu", "Magenta" }
local COLOR_LETTERS = { "R", "O", "J", "V", "B", "M" }

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

local function otherSide(side) return (side == "player1") and "player2" or "player1" end

local function newGame()
  return {
    codes = { player1 = nil, player2 = nil }, -- {c1,c2,c3,c4} une fois valide (indices de couleur 1-6)
    draft = { player1 = {}, player2 = {} },   -- code/essai en cours de composition
    guesses = { player1 = {}, player2 = {} }, -- guesses[p] = liste de { code={...}, black=, white= } -- essais que P a faits CONTRE l'adversaire
    phase = "setup", -- "setup" | "playing" | "gameOver"
    currentTurn = "player1",
    gameOver = false,
    winner = nil, -- "player1" | "player2" | "draw"
  }
end

-- Calcule le score (bien places / bonnes couleurs mal placees) d'un
-- essai `guess` par rapport au code secret `secret`.
local function scoreGuess(secret, guess)
  local black = 0
  local secretRemain, guessRemain = {}, {}
  for i = 1, CODE_LENGTH do
    if secret[i] == guess[i] then
      black = black + 1
    else
      secretRemain[secret[i]] = (secretRemain[secret[i]] or 0) + 1
      guessRemain[guess[i]] = (guessRemain[guess[i]] or 0) + 1
    end
  end
  local white = 0
  for color, n in pairs(guessRemain) do
    white = white + math.min(n, secretRemain[color] or 0)
  end
  return black, white
end

local function pickColor(G, side, colorIdx)
  if G.gameOver then return false end
  if G.phase == "playing" and G.currentTurn ~= side then return false end
  if G.phase == "setup" and G.codes[side] then return false end -- deja valide, plus modifiable
  local d = G.draft[side]
  if #d >= CODE_LENGTH then return false end
  if colorIdx < 1 or colorIdx > #COLOR_NAMES then return false end
  table.insert(d, colorIdx)
  return true
end

local function undoColor(G, side)
  if G.gameOver then return false end
  if G.phase == "playing" and G.currentTurn ~= side then return false end
  if G.phase == "setup" and G.codes[side] then return false end
  local d = G.draft[side]
  if #d == 0 then return false end
  table.remove(d)
  return true
end

local function checkGameEnd(G)
  local p1Done = #G.guesses.player1 >= MAX_GUESSES
  local p2Done = #G.guesses.player2 >= MAX_GUESSES
  if p1Done and p2Done then
    G.gameOver = true
    G.winner = "draw"
  end
end

-- Fait passer le tour, en sautant un joueur qui a deja epuise ses
-- essais (et termine la partie si les 2 sont a court).
local function advanceTurn(G, from)
  local nextSide = otherSide(from)
  if #G.guesses[nextSide] >= MAX_GUESSES then
    if #G.guesses[from] >= MAX_GUESSES then
      G.gameOver = true
      G.winner = "draw"
      return
    end
    -- l'autre ne peut plus jouer : on reste sur `from`
    G.currentTurn = from
  else
    G.currentTurn = nextSide
  end
end

-- Valide le code/essai en cours de `side`. En phase "setup", ca fixe
-- son code secret. En phase "playing", ca soumet un essai contre le
-- code adverse.
local function confirmDraft(G, side)
  if G.gameOver then return false end
  local d = G.draft[side]
  if #d ~= CODE_LENGTH then return false end

  if G.phase == "setup" then
    if G.codes[side] then return false end
    G.codes[side] = d
    G.draft[side] = {}
    if G.codes.player1 and G.codes.player2 then
      G.phase = "playing"
      G.currentTurn = "player1"
    end
    return true
  end

  if G.phase == "playing" then
    if G.currentTurn ~= side then return false end
    local opponent = otherSide(side)
    local black, white = scoreGuess(G.codes[opponent], d)
    table.insert(G.guesses[side], { code = d, black = black, white = white })
    G.draft[side] = {}

    if black == CODE_LENGTH then
      G.gameOver = true
      G.winner = side
      return true
    end

    checkGameEnd(G)
    if not G.gameOver then
      advanceTurn(G, side)
    end
    return true
  end

  return false
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, side, action)
  if action.type == "pick" then
    pickColor(G, side, action.color)
    return G, false
  elseif action.type == "undo" then
    undoColor(G, side)
    return G, false
  elseif action.type == "confirm" then
    confirmDraft(G, side)
    return G, false
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

_G.__mm_internal = {
  newGame = newGame,
  scoreGuess = scoreGuess,
  pickColor = pickColor,
  undoColor = undoColor,
  confirmDraft = confirmDraft,
  handleAction = handleAction,
  CODE_LENGTH = CODE_LENGTH,
  MAX_GUESSES = MAX_GUESSES,
  COLOR_NAMES = COLOR_NAMES,
}

if _G.__MM_TEST_MODE then return end

-- ============================================================
-- A PARTIR D'ICI : peripheriques, rendu, boucle de jeu
-- (non charge en mode test)
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
local monitorCfg = monitorsLib.load(resolveNear(MONITORS_CONFIG_PATH))
monitorsLib.requireFloors(monitorCfg)

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

local SCREENS = {
  wall1  = { mon = wall1,  player = "player1", mode = "wall" },
  floor1 = { mon = floor1, player = "player1", mode = "floor" },
  wall2  = { mon = wall2,  player = "player2", mode = "wall" },
  floor2 = { mon = floor2, player = "player2", mode = "floor" },
}
local SCREEN_KEYS = { "wall1", "floor1", "wall2", "floor2" }
local NAME_TO_KEY = {
  [WALL_1_NAME] = "wall1", [FLOOR_1_NAME] = "floor1",
  [WALL_2_NAME] = "wall2", [FLOOR_2_NAME] = "floor2",
}

-- ------------------------------------------------------------
-- Rendu
-- ------------------------------------------------------------

local COLOR_CC = { colors.red, colors.orange, colors.yellow, colors.lime, colors.lightBlue, colors.magenta }
local PEG_W = 3

local function drawPeg(mon, x, y, colorIdx, dim)
  local bg = dim and colors.gray or COLOR_CC[colorIdx]
  local fg = dim and colors.lightGray or colors.black
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  local label = COLOR_LETTERS[colorIdx]
  mon.write(" " .. label .. " ")
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
end

local function drawEmptyPeg(mon, x, y)
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.lightGray)
  mon.write("[ ]")
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
  mon.setBackgroundColor(colors.black)
end

-- Palette de couleurs cliquable (6 boutons). Retourne les zones.
local function drawPalette(mon, x, y, clickable)
  local zones = {}
  for i = 1, #COLOR_NAMES do
    local bx = x + (i - 1) * (PEG_W + 1)
    mon.setCursorPos(bx, y)
    mon.setBackgroundColor(COLOR_CC[i])
    mon.setTextColor(colors.black)
    mon.write(" " .. COLOR_LETTERS[i] .. " ")
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    if clickable then
      zones[#zones + 1] = { x1 = bx, y1 = y, x2 = bx + PEG_W - 1, y2 = y, action = "pick", color = i }
    end
  end
  return zones
end

local function drawDraft(mon, x, y, draft, clickable)
  local zones = {}
  for i = 1, CODE_LENGTH do
    local px = x + (i - 1) * (PEG_W + 1)
    if draft[i] then
      drawPeg(mon, px, y, draft[i], false)
    else
      drawEmptyPeg(mon, px, y)
    end
  end
  if clickable then
    local undoX = x + CODE_LENGTH * (PEG_W + 1)
    drawButton(mon, undoX, y, 9, "Effacer", colors.lightGray, colors.black)
    zones[#zones + 1] = { x1 = undoX, y1 = y, x2 = undoX + 8, y2 = y, action = "undo" }
  end
  return zones
end

local function drawGuessRow(mon, x, y, entry)
  for i = 1, CODE_LENGTH do
    drawPeg(mon, x + (i - 1) * (PEG_W + 1), y, entry.code[i], false)
  end
  local scoreX = x + CODE_LENGTH * (PEG_W + 1)
  mon.setCursorPos(scoreX, y)
  mon.setTextColor(colors.white)
  mon.write(string.format("%d bien / %d mal places", entry.black, entry.white))
end

-- ------------------------------------------------------------
-- Ecran MUR : preparation de ton code, puis tes essais contre le
-- code adverse.
-- ------------------------------------------------------------
local function renderWall(G, mon, side)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}
  local opponent = otherSide(side)

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)

  if G.gameOver then
    if G.winner == "draw" then
      mon.write("Match nul !")
    elseif G.winner == side then
      mon.setTextColor(colors.lime)
      mon.write("Tu as trouve le code adverse !")
    else
      mon.setTextColor(colors.red)
      mon.write("L'adversaire a trouve ton code...")
    end
    mon.setTextColor(colors.white)
    mon.setCursorPos(1, 2)
    mon.write("Code adverse : ")
    for i = 1, CODE_LENGTH do
      drawPeg(mon, 15 + (i - 1) * (PEG_W + 1), 2, G.codes[opponent][i], false)
    end

    local by = 4
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, by, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = by, x2 = btnW, y2 = by, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, by, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = by, x2 = quitX + btnW - 1, y2 = by, action = "quit" }
    return clickZones
  end

  if G.phase == "setup" then
    if G.codes[side] then
      mon.write("Code valide -- en attente de l'adversaire...")
      return clickZones
    end
    mon.write("Compose ton code secret")

    mon.setCursorPos(1, 3)
    mon.setTextColor(colors.lightGray)
    mon.write("Ton code :")
    local draftZones = drawDraft(mon, 1, 4, G.draft[side], #G.draft[side] > 0)
    for _, z in ipairs(draftZones) do clickZones[#clickZones + 1] = z end

    mon.setCursorPos(1, 6)
    mon.setTextColor(colors.lightGray)
    mon.write("Couleurs :")
    local paletteZones = drawPalette(mon, 1, 7, #G.draft[side] < CODE_LENGTH)
    for _, z in ipairs(paletteZones) do clickZones[#clickZones + 1] = z end

    if #G.draft[side] == CODE_LENGTH then
      drawButton(mon, 1, 9, 16, "Valider le code", colors.lime, colors.black)
      clickZones[#clickZones + 1] = { x1 = 1, y1 = 9, x2 = 16, y2 = 9, action = "confirm" }
    end
    return clickZones
  end

  -- phase "playing"
  local myTurn = G.currentTurn == side
  if myTurn then
    mon.setTextColor(colors.lime)
    mon.write("A toi de proposer un essai !")
  else
    mon.setTextColor(colors.lightGray)
    mon.write("Tour de l'adversaire...")
  end
  mon.setTextColor(colors.white)
  mon.setCursorPos(1, 2)
  mon.write(string.format("Essais : %d / %d", #G.guesses[side], MAX_GUESSES))

  local y = 4
  if myTurn then
    mon.setCursorPos(1, y)
    mon.setTextColor(colors.lightGray)
    mon.write("Ton essai :")
    local draftZones = drawDraft(mon, 1, y + 1, G.draft[side], #G.draft[side] > 0)
    for _, z in ipairs(draftZones) do clickZones[#clickZones + 1] = z end

    mon.setCursorPos(1, y + 3)
    mon.setTextColor(colors.lightGray)
    mon.write("Couleurs :")
    local paletteZones = drawPalette(mon, 1, y + 4, #G.draft[side] < CODE_LENGTH)
    for _, z in ipairs(paletteZones) do clickZones[#clickZones + 1] = z end

    if #G.draft[side] == CODE_LENGTH then
      drawButton(mon, 1, y + 6, 16, "Valider l'essai", colors.lime, colors.black)
      clickZones[#clickZones + 1] = { x1 = 1, y1 = y + 6, x2 = 16, y2 = y + 6, action = "confirm" }
    end
    y = y + 8
  end

  mon.setCursorPos(1, y)
  mon.setTextColor(colors.lightGray)
  mon.write("Tes essais precedents :")
  mon.setTextColor(colors.white)
  local guesses = G.guesses[side]
  local startRow = y + 1
  local maxRows = h - startRow + 1
  local firstShown = math.max(1, #guesses - maxRows + 1)
  local row = 0
  for i = firstShown, #guesses do
    drawGuessRow(mon, 1, startRow + row, guesses[i])
    row = row + 1
  end

  return clickZones
end

-- ------------------------------------------------------------
-- Ecran SOL : ton propre code (reference) + les essais de
-- l'adversaire contre ce code.
-- ------------------------------------------------------------
local function renderFloor(G, mon, side)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local opponent = otherSide(side)

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write("Ton code secret :")
  if G.codes[side] then
    for i = 1, CODE_LENGTH do
      drawPeg(mon, 19 + (i - 1) * (PEG_W + 1), 1, G.codes[side][i], false)
    end
  else
    mon.setCursorPos(19, 1)
    mon.setTextColor(colors.lightGray)
    mon.write("(pas encore compose)")
  end
  mon.setTextColor(colors.white)

  mon.setCursorPos(1, 3)
  mon.setTextColor(colors.lightGray)
  mon.write("Essais de l'adversaire contre ton code :")
  mon.setTextColor(colors.white)

  local guesses = G.guesses[opponent]
  local startRow = 4
  local maxRows = h - startRow + 1
  local firstShown = math.max(1, #guesses - maxRows + 1)
  local row = 0
  for i = firstShown, #guesses do
    drawGuessRow(mon, 1, startRow + row, guesses[i])
    row = row + 1
  end

  return {} -- ecran purement informatif, jamais interactif
end

local lastClickZones = { wall1 = {}, floor1 = {}, wall2 = {}, floor2 = {} }
_G.__MM_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

local function redrawAll(G)
  for _, key in ipairs(SCREEN_KEYS) do
    local s = SCREENS[key]
    if s.mode == "wall" then
      lastClickZones[key] = renderWall(G, s.mon, s.player)
    else
      lastClickZones[key] = renderFloor(G, s.mon, s.player)
    end
  end
end

local function zoneAt(zones, x, y)
  for _, z in ipairs(zones) do
    if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z end
  end
  return nil
end

local function zoneToAction(zone)
  if zone.action == "pick" then return { type = "pick", color = zone.color } end
  if zone.action == "undo" then return { type = "undo" } end
  if zone.action == "confirm" then return { type = "confirm" } end
  if zone.action == "restart" then return { type = "restart" } end
  if zone.action == "quit" then return { type = "quit" } end
  return nil
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Mastermind (2 joueurs) lance. Ctrl+T pour arreter.")

if _G.__MM_AUTOPILOT then
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__MM_AUTOPILOT_GAMES do
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
      G = handleAction(G, SCREENS[key].player, action)
      redrawAll(G)
      totalTurns = totalTurns + 1
      if chosen.action == "restart" then gamesPlayed = gamesPlayed + 1 end
    end
    if totalTurns > _G.__MM_AUTOPILOT_GAMES * 6000 then
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
        G, quit = handleAction(G, SCREENS[key].player, action)
        if quit then
          for _, k in ipairs(SCREEN_KEYS) do
            local mon = SCREENS[k].mon
            mon.setBackgroundColor(colors.black)
            mon.clear()
          end
          print("Mastermind ferme.")
          return
        end
        redrawAll(G)
      end
    end
  end
end