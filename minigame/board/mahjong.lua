--[[
  mahjong_game.lua
  ---------------------------------------------------------------
  luaforcc :: Mahjong "siamois" 2 joueurs, 4 moniteurs (mur+sol par
  joueur, comme la bataille navale).

  Set complet traditionnel : man/pin/sou (1-9 x4 chacun) + vents
  (E/S/O/N x4) + dragons (blanc/vert/rouge x4) = 136 tuiles.

  SIMPLIFICATIONS ASSUMEES (mahjong complet = tres complexe) :
    - Pas de score/yaku : la premiere main valide (4 combinaisons +
      1 paire, forme standard, OU 7 paires) gagne, point final.
    - Pas de riichi, pas de dora, pas de kan (carre de 4).
    - Pas de mur mort separe : toute la pioche est piochable.
    - Pioche epuisee sans vainqueur -> match nul.

  Regles de tuiles :
    - PIOCHER/DEFAUSSER : tour normal.
    - PON : reclamer la defausse adverse avec 2 tuiles identiques
      en main pour former un brelan.
    - CHI : reclamer la defausse adverse avec 2 tuiles adjacentes
      de la meme famille pour former une suite (toujours autorise
      entre les 2 seuls joueurs).
    - RON : la defausse adverse complete directement ta main.
    - TSUMO : ta propre pioche complete directement ta main.

  Ecrans : MUR (monitors.cfg ligne 1/2) = defausse commune + statut
  + boutons d'appel (pon/chi/ron) quand disponibles. SOL (ligne 4/5,
  floor1/floor2) = ta main privee + tes combinaisons posees.

  Tuiles affichees en etiquette texte + couleur par famille (comme
  Puissance4/Bataille navale), pas en pictogramme.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 1
local FLOOR_Y_OFFSET = 2

-- ============================================================
-- TUILES
-- ============================================================

local TILE_TYPES = {}
local TILE_INDEX = {} -- id -> index dans TILE_TYPES (ordre canonique)

local function addTile(id, kind, suit, num, label)
  TILE_TYPES[#TILE_TYPES + 1] = { id = id, kind = kind, suit = suit, num = num, label = label }
  TILE_INDEX[id] = #TILE_TYPES
end

for _, suit in ipairs({ "m", "p", "s" }) do
  for n = 1, 9 do
    addTile(n .. suit, "suit", suit, n, n .. suit)
  end
end
for _, w in ipairs({ "E", "S", "W", "N" }) do
  addTile(w, "wind", nil, nil, w)
end
for _, d in ipairs({ { "Wh", "Blanc" }, { "Gr", "Vert" }, { "Rd", "Rouge" } }) do
  addTile(d[1], "dragon", nil, nil, d[1])
end

local function makeDeck()
  local deck = {}
  for _, t in ipairs(TILE_TYPES) do
    for _ = 1, 4 do deck[#deck + 1] = t.id end
  end
  return deck
end

local function shuffle(list)
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

local function tileInfo(id) return TILE_TYPES[TILE_INDEX[id]] end

local function sortHand(hand)
  table.sort(hand, function(a, b) return TILE_INDEX[a] < TILE_INDEX[b] end)
end

-- ============================================================
-- VALIDATION DE MAIN (4 combinaisons + 1 paire, ou 7 paires)
-- ============================================================

local function countsOf(list)
  local c = {}
  for _, id in ipairs(list) do c[id] = (c[id] or 0) + 1 end
  return c
end

-- Essaie de decomposer `counts` en exactement `needed` combinaisons
-- (brelans ou suites), en consommant toujours la plus petite tuile
-- restante (technique standard, prouvee correcte/complete).
local function decomposeMelds(counts, needed)
  if needed == 0 then
    for _, v in pairs(counts) do
      if v > 0 then return false end
    end
    return true
  end

  -- trouve la plus petite tuile restante (ordre canonique)
  local firstId
  for _, t in ipairs(TILE_TYPES) do
    if (counts[t.id] or 0) > 0 then firstId = t.id break end
  end
  if not firstId then return false end

  local info = tileInfo(firstId)

  -- option brelan
  if (counts[firstId] or 0) >= 3 then
    counts[firstId] = counts[firstId] - 3
    if decomposeMelds(counts, needed - 1) then
      counts[firstId] = counts[firstId] + 3
      return true
    end
    counts[firstId] = counts[firstId] + 3
  end

  -- option suite (uniquement tuiles numerotees, jusqu'a n+2 <= 9)
  if info.kind == "suit" and info.num <= 7 then
    local id2 = (info.num + 1) .. info.suit
    local id3 = (info.num + 2) .. info.suit
    if (counts[id2] or 0) >= 1 and (counts[id3] or 0) >= 1 then
      counts[firstId] = counts[firstId] - 1
      counts[id2] = counts[id2] - 1
      counts[id3] = counts[id3] - 1
      if decomposeMelds(counts, needed - 1) then
        counts[firstId] = counts[firstId] + 1
        counts[id2] = counts[id2] + 1
        counts[id3] = counts[id3] + 1
        return true
      end
      counts[firstId] = counts[firstId] + 1
      counts[id2] = counts[id2] + 1
      counts[id3] = counts[id3] + 1
    end
  end

  return false
end

-- Verifie si `concealed` (liste de tuiles) + `openMelds` (deja
-- valides par construction) forment une main complete.
local function isCompleteConcealed(concealed, neededMelds)
  local expectedCount = 3 * neededMelds + 2
  if #concealed ~= expectedCount then return false end

  local counts = countsOf(concealed)
  for _, t in ipairs(TILE_TYPES) do
    if (counts[t.id] or 0) >= 2 then
      counts[t.id] = counts[t.id] - 2
      if decomposeMelds(counts, neededMelds) then
        counts[t.id] = counts[t.id] + 2
        return true
      end
      counts[t.id] = counts[t.id] + 2
    end
  end
  return false
end

local function isChiitoitsu(concealed)
  if #concealed ~= 14 then return false end
  local counts = countsOf(concealed)
  local pairs_ = 0
  for _, v in pairs(counts) do
    if v == 2 then pairs_ = pairs_ + 1 elseif v ~= 0 then return false end
  end
  return pairs_ == 7
end

-- Fonction publique : la main (concealed + melds ouverts) est-elle
-- complete ?
local function isWinningHand(concealed, numOpenMelds)
  local neededMelds = 4 - numOpenMelds
  if isCompleteConcealed(concealed, neededMelds) then return true end
  if numOpenMelds == 0 and isChiitoitsu(concealed) then return true end
  return false
end

-- ============================================================
-- MOTEUR DE JEU
-- ============================================================

local function otherPlayer(p) return (p == 1) and 2 or 1 end

local function newGame()
  local deck = makeDeck()
  shuffle(deck)

  local hands = { {}, {} }
  for _ = 1, 13 do
    table.insert(hands[1], table.remove(deck))
    table.insert(hands[2], table.remove(deck))
  end
  sortHand(hands[1])
  sortHand(hands[2])

  return {
    wall = deck,
    discards = {}, -- { {id=, by=}, ... } dans l'ordre chronologique
    hands = hands,
    melds = { {}, {} }, -- melds[p] = { {type="pon"/"chi", tiles={id,id,id}, from=}, ... }
    currentPlayer = 1,
    phase = "draw", -- "draw" | "discard" | "call" | "gameOver"
    pendingDiscard = nil,
    callOptions = nil, -- { player=, ron=bool, pon=bool, chi={ {consumed={id,id}, result={n1,n2,n3}}, ... } }
    canTsumo = false,
    gameOver = false,
    winner = nil,
    winType = nil, -- "tsumo" | "ron" | "draw"
  }
end

local function computeCallOptions(G, discardId, discarderIndex)
  local responder = otherPlayer(discarderIndex)
  local hand = G.hands[responder]
  local counts = countsOf(hand)
  local opts = { player = responder, ron = false, pon = false, chi = {} }

  -- RON : la tuile completerait la main du repondeur
  local trial = {}
  for _, id in ipairs(hand) do trial[#trial + 1] = id end
  trial[#trial + 1] = discardId
  if isWinningHand(trial, #G.melds[responder]) then
    opts.ron = true
  end

  -- PON : 2 tuiles identiques en main
  if (counts[discardId] or 0) >= 2 then
    opts.pon = true
  end

  -- CHI : uniquement tuiles numerotees, patterns possibles
  local info = tileInfo(discardId)
  if info.kind == "suit" then
    local n, s = info.num, info.suit
    local function has(k) return (counts[k .. s] or 0) >= 1 end
    if n >= 3 and has(n - 2) and has(n - 1) then
      opts.chi[#opts.chi + 1] = { consumed = { (n - 2) .. s, (n - 1) .. s }, result = { n - 2, n - 1, n } }
    end
    if n >= 2 and n <= 8 and has(n - 1) and has(n + 1) then
      opts.chi[#opts.chi + 1] = { consumed = { (n - 1) .. s, (n + 1) .. s }, result = { n - 1, n, n + 1 } }
    end
    if n <= 7 and has(n + 1) and has(n + 2) then
      opts.chi[#opts.chi + 1] = { consumed = { (n + 1) .. s, (n + 2) .. s }, result = { n, n + 1, n + 2 } }
    end
  end

  return opts
end

local function removeOne(list, id)
  for i, v in ipairs(list) do
    if v == id then table.remove(list, i) return true end
  end
  return false
end

-- Pioche pour `playerIndex`. Retourne true si l'action a eu lieu
-- (y compris si ca termine la partie sur pioche epuisee).
local function drawTile(G, playerIndex)
  if G.gameOver then return false end
  if G.phase ~= "draw" or G.currentPlayer ~= playerIndex then return false end

  if #G.wall == 0 then
    G.gameOver = true
    G.winner = nil
    G.winType = "draw"
    G.phase = "gameOver"
    return true
  end

  local tile = table.remove(G.wall)
  table.insert(G.hands[playerIndex], tile)
  sortHand(G.hands[playerIndex])

  G.canTsumo = isWinningHand(G.hands[playerIndex], #G.melds[playerIndex])
  G.phase = "discard"
  return true
end

local function discardTile(G, playerIndex, tileId)
  if G.gameOver then return false end
  if G.phase ~= "discard" or G.currentPlayer ~= playerIndex then return false end
  if not removeOne(G.hands[playerIndex], tileId) then return false end

  table.insert(G.discards, { id = tileId, by = playerIndex })
  G.pendingDiscard = { id = tileId, by = playerIndex }
  G.canTsumo = false

  local opts = computeCallOptions(G, tileId, playerIndex)
  if opts.ron or opts.pon or #opts.chi > 0 then
    G.callOptions = opts
    G.currentPlayer = opts.player
    G.phase = "call"
  else
    G.callOptions = nil
    G.currentPlayer = otherPlayer(playerIndex)
    G.phase = "draw"
  end
  return true
end

local function declareTsumo(G, playerIndex)
  if G.gameOver then return false end
  if G.phase ~= "discard" or G.currentPlayer ~= playerIndex or not G.canTsumo then return false end
  G.gameOver = true
  G.winner = playerIndex
  G.winType = "tsumo"
  G.phase = "gameOver"
  return true
end

local function declareRon(G, playerIndex)
  if G.gameOver then return false end
  if G.phase ~= "call" or G.currentPlayer ~= playerIndex then return false end
  if not (G.callOptions and G.callOptions.ron) then return false end
  G.gameOver = true
  G.winner = playerIndex
  G.winType = "ron"
  G.phase = "gameOver"
  return true
end

local function declarePass(G, playerIndex)
  if G.gameOver then return false end
  if G.phase ~= "call" or G.currentPlayer ~= playerIndex then return false end
  G.callOptions = nil
  G.pendingDiscard = nil
  G.phase = "draw"
  -- currentPlayer reste le repondeur : c'est maintenant SON tour de piocher
  return true
end

local function declarePon(G, playerIndex)
  if G.gameOver then return false end
  if G.phase ~= "call" or G.currentPlayer ~= playerIndex then return false end
  if not (G.callOptions and G.callOptions.pon) then return false end

  local claimedId = G.pendingDiscard.id
  -- retire la tuile de la defausse (la derniere posee)
  table.remove(G.discards)

  local hand = G.hands[playerIndex]
  removeOne(hand, claimedId)
  removeOne(hand, claimedId)
  table.insert(G.melds[playerIndex], { type = "pon", tiles = { claimedId, claimedId, claimedId }, from = G.pendingDiscard.by })

  G.callOptions = nil
  G.pendingDiscard = nil
  G.currentPlayer = playerIndex
  G.phase = "discard"
  return true
end

local function declareChi(G, playerIndex, patternIndex)
  if G.gameOver then return false end
  if G.phase ~= "call" or G.currentPlayer ~= playerIndex then return false end
  if not (G.callOptions and G.callOptions.chi and G.callOptions.chi[patternIndex]) then return false end

  local pattern = G.callOptions.chi[patternIndex]
  local claimedId = G.pendingDiscard.id
  table.remove(G.discards)

  local hand = G.hands[playerIndex]
  for _, id in ipairs(pattern.consumed) do removeOne(hand, id) end
  table.insert(G.melds[playerIndex], { type = "chi", tiles = { pattern.consumed[1], pattern.consumed[2], claimedId }, from = G.pendingDiscard.by })

  G.callOptions = nil
  G.pendingDiscard = nil
  G.currentPlayer = playerIndex
  G.phase = "discard"
  return true
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, playerIndex, action)
  if action.type == "draw" then
    drawTile(G, playerIndex)
  elseif action.type == "discard" then
    discardTile(G, playerIndex, action.tile)
  elseif action.type == "tsumo" then
    declareTsumo(G, playerIndex)
  elseif action.type == "ron" then
    declareRon(G, playerIndex)
  elseif action.type == "pon" then
    declarePon(G, playerIndex)
  elseif action.type == "chi" then
    declareChi(G, playerIndex, action.pattern)
  elseif action.type == "pass" then
    declarePass(G, playerIndex)
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

_G.__mj_internal = {
  newGame = newGame,
  drawTile = drawTile,
  discardTile = discardTile,
  declareTsumo = declareTsumo,
  declareRon = declareRon,
  declarePon = declarePon,
  declareChi = declareChi,
  declarePass = declarePass,
  handleAction = handleAction,
  isWinningHand = isWinningHand,
  isChiitoitsu = isChiitoitsu,
  computeCallOptions = computeCallOptions,
  tileInfo = tileInfo,
  sortHand = sortHand,
  TILE_TYPES = TILE_TYPES,
  makeDeck = makeDeck,
}

if _G.__MJ_TEST_MODE then return end

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
  wall1  = { mon = wall1,  player = 1, mode = "wall" },
  floor1 = { mon = floor1, player = 1, mode = "floor" },
  wall2  = { mon = wall2,  player = 2, mode = "wall" },
  floor2 = { mon = floor2, player = 2, mode = "floor" },
}
local SCREEN_KEYS = { "wall1", "floor1", "wall2", "floor2" }
local NAME_TO_KEY = {
  [WALL_1_NAME] = "wall1", [FLOOR_1_NAME] = "floor1",
  [WALL_2_NAME] = "wall2", [FLOOR_2_NAME] = "floor2",
}

-- ------------------------------------------------------------
-- Rendu
-- ------------------------------------------------------------

local COLOR_BY_KIND = {
  m = colors.red,
  p = colors.lightBlue,
  s = colors.lime,
  wind = colors.lightGray,
  dragon = colors.yellow,
}

local function tileColor(id)
  local info = tileInfo(id)
  if info.kind == "suit" then return COLOR_BY_KIND[info.suit] end
  return COLOR_BY_KIND[info.kind]
end

local TILE_W = 3 -- largeur d'une tuile affichee, ex " 5m"/" E "

local function drawTileCell(mon, x, y, id, dim)
  local info = tileInfo(id)
  local bg = tileColor(id)
  local fg = colors.black
  if dim then bg, fg = colors.gray, colors.lightGray end
  mon.setCursorPos(x, y)
  mon.setBackgroundColor(bg)
  mon.setTextColor(fg)
  local label = info.label
  local pad = TILE_W - #label
  local left = math.floor(pad / 2)
  mon.write(string.rep(" ", left) .. label .. string.rep(" ", pad - left))
  mon.setBackgroundColor(colors.black)
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

local function statusText(G, playerIndex)
  if G.gameOver then
    if G.winType == "draw" then return "Match nul (pioche epuisee)" end
    if G.winner == playerIndex then
      return (G.winType == "tsumo") and "Tsumo ! Tu as gagne !" or "Ron ! Tu as gagne !"
    else
      return (G.winType == "tsumo") and "L'adversaire a fait tsumo..." or "L'adversaire a fait ron..."
    end
  end
  if G.phase == "call" and G.currentPlayer == playerIndex then
    return "Un appel est possible !"
  end
  if G.currentPlayer ~= playerIndex then
    return "Tour de l'adversaire..."
  end
  if G.phase == "draw" then return "A toi de piocher" end
  if G.phase == "discard" then return G.canTsumo and "Tsumo possible ! Ou defausse" or "A toi de defausser" end
  return ""
end

-- Ecran MUR : defausse commune + statut + appels
local function renderWall(G, mon, playerIndex)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write(statusText(G, playerIndex))

  mon.setCursorPos(1, 2)
  mon.setTextColor(colors.lightGray)
  mon.write("Pioche restante: " .. #G.wall)

  -- boutons d'appel (uniquement pour le joueur concerne)
  local btnY = 3
  if not G.gameOver and G.phase == "call" and G.currentPlayer == playerIndex then
    local x = 1
    if G.callOptions.ron then
      drawButton(mon, x, btnY, 7, "RON", colors.red, colors.white)
      clickZones[#clickZones + 1] = { x1 = x, y1 = btnY, x2 = x + 6, y2 = btnY, action = "ron" }
      x = x + 8
    end
    if G.callOptions.pon then
      drawButton(mon, x, btnY, 7, "PON", colors.orange, colors.black)
      clickZones[#clickZones + 1] = { x1 = x, y1 = btnY, x2 = x + 6, y2 = btnY, action = "pon" }
      x = x + 8
    end
    for i, pat in ipairs(G.callOptions.chi) do
      local label = "CHI " .. pat.result[1] .. pat.result[2] .. pat.result[3]
      local bw = #label + 2
      drawButton(mon, x, btnY, bw, label, colors.cyan, colors.black)
      clickZones[#clickZones + 1] = { x1 = x, y1 = btnY, x2 = x + bw - 1, y2 = btnY, action = "chi", pattern = i }
      x = x + bw + 1
    end
    drawButton(mon, x, btnY, 9, "Passer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = x, y1 = btnY, x2 = x + 8, y2 = btnY, action = "pass" }
  end

  if G.gameOver then
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, btnY, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = btnY, x2 = btnW, y2 = btnY, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, btnY, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = btnY, x2 = quitX + btnW - 1, y2 = btnY, action = "quit" }
  end

  -- defausse commune : grille de tuiles, plus recentes en dernier
  mon.setCursorPos(1, btnY + 2)
  mon.setTextColor(colors.lightGray)
  mon.write("Defausse :")
  local cols = math.max(1, math.floor(w / (TILE_W + 1)))
  local startY = btnY + 3
  for i, disc in ipairs(G.discards) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local x = 1 + col * (TILE_W + 1)
    local y = startY + row
    if y <= h then
      drawTileCell(mon, x, y, disc.id, disc.by ~= playerIndex)
    end
  end

  return clickZones
end

-- Ecran SOL : main privee + melds poses
-- Legende des familles de tuiles, affichee tout en haut de l'ecran
-- au sol (au-dessus de tout le reste, y compris le statut).
local function drawLegend(mon, w)
  mon.setBackgroundColor(colors.black)
  mon.setCursorPos(1, 1)
  mon.setTextColor(COLOR_BY_KIND.m)
  mon.write("m")
  mon.setTextColor(colors.white)
  mon.write("=Caractere  ")
  mon.setTextColor(COLOR_BY_KIND.p)
  mon.write("p")
  mon.setTextColor(colors.white)
  mon.write("=Cercle  ")
  mon.setTextColor(COLOR_BY_KIND.s)
  mon.write("s")
  mon.setTextColor(colors.white)
  mon.write("=Bambou")

  mon.setCursorPos(1, 2)
  mon.setTextColor(COLOR_BY_KIND.wind)
  mon.write("E/S/W/N")
  mon.setTextColor(colors.white)
  mon.write("=Vent  ")
  mon.setTextColor(COLOR_BY_KIND.dragon)
  mon.write("Wh/Gr/Rd")
  mon.setTextColor(colors.white)
  mon.write("=Dragon")
end

local LEGEND_HEIGHT = 2

local function renderFloor(G, mon, playerIndex)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}
  local yOff = FLOOR_Y_OFFSET + LEGEND_HEIGHT

  drawLegend(mon, w)

  mon.setCursorPos(1, 1 + yOff)
  mon.setTextColor(colors.white)
  mon.write(statusText(G, playerIndex))

  local myTurn = (not G.gameOver) and G.currentPlayer == playerIndex
  local canDiscard = myTurn and G.phase == "discard"
  local canTsumo = canDiscard and G.canTsumo

  if canTsumo then
    drawButton(mon, 1, 2 + yOff, 14, "TSUMO !", colors.lime, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = 2 + yOff, x2 = 14, y2 = 2 + yOff, action = "tsumo" }
  end

  -- melds poses (publics, mais affiches ici pour reference perso)
  local meldsY = 3 + yOff
  mon.setCursorPos(1, meldsY)
  mon.setTextColor(colors.lightGray)
  mon.write("Combinaisons posees:")
  local mx = 1
  local my = meldsY + 1
  for _, meld in ipairs(G.melds[playerIndex]) do
    for _, id in ipairs(meld.tiles) do
      if mx + TILE_W > w then mx = 1 my = my + 1 end
      drawTileCell(mon, mx, my, id, false)
      mx = mx + TILE_W + 1
    end
    mx = mx + 1
  end

  -- main privee
  local handY = my + 2
  mon.setCursorPos(1, handY - 1)
  mon.setTextColor(colors.lightGray)
  mon.write("Ta main (" .. #G.hands[playerIndex] .. ") :")

  local cols = math.max(1, math.floor(w / (TILE_W + 1)))
  for i, id in ipairs(G.hands[playerIndex]) do
    local col = (i - 1) % cols
    local row = math.floor((i - 1) / cols)
    local x = 1 + col * (TILE_W + 1)
    local y = handY + row
    if y <= h then
      drawTileCell(mon, x, y, id, false)
      if canDiscard then
        clickZones[#clickZones + 1] = {
          x1 = x, y1 = y, x2 = x + TILE_W - 1, y2 = y, action = "discard", tile = id,
        }
      end
    end
  end

  if myTurn and G.phase == "draw" then
    local by = math.min(h, handY + math.ceil(#G.hands[playerIndex] / cols) + 1)
    drawButton(mon, 1, by, 14, "PIOCHER", colors.orange, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = by, x2 = 14, y2 = by, action = "draw" }
  end

  return clickZones
end

local lastClickZones = { wall1 = {}, floor1 = {}, wall2 = {}, floor2 = {} }
_G.__MJ_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

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

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Mahjong siamois lance. Ctrl+T pour arreter.")

local function zoneToAction(zone)
  if zone.action == "draw" then return { type = "draw" } end
  if zone.action == "discard" then return { type = "discard", tile = zone.tile } end
  if zone.action == "tsumo" then return { type = "tsumo" } end
  if zone.action == "ron" then return { type = "ron" } end
  if zone.action == "pon" then return { type = "pon" } end
  if zone.action == "chi" then return { type = "chi", pattern = zone.pattern } end
  if zone.action == "pass" then return { type = "pass" } end
  if zone.action == "restart" then return { type = "restart" } end
  if zone.action == "quit" then return { type = "quit" } end
  return nil
end

if _G.__MJ_AUTOPILOT then
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__MJ_AUTOPILOT_GAMES do
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
    local chosen = zones[math.random(#zones)]
    local action = zoneToAction(chosen)
    if action then
      G = handleAction(G, SCREENS[key].player, action)
      redrawAll(G)
      totalTurns = totalTurns + 1
      if chosen.action == "restart" then gamesPlayed = gamesPlayed + 1 end
    end
    if totalTurns > _G.__MJ_AUTOPILOT_GAMES * 4000 then
      error("Autopilot: trop de tours sans terminer assez de parties (deadlock probable)")
    end
    ::continue::
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
          print("Mahjong ferme.")
          return
        end
        redrawAll(G)
      end
    end
  end
end