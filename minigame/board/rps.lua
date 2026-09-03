--[[
  rps_game.lua
  ---------------------------------------------------------------
  luaforcc :: Pierre-Feuille-Ciseaux, 2 joueurs, premier a 5 points.

  2 ecrans MURAUX prives (monitors.cfg lignes 1/2, comme Uno) : les
  choix sont simultanes et secrets jusqu'a ce que les 2 joueurs
  aient choisi. Pas besoin d'ecran au sol ni partage.

  Regle : Pierre bat Ciseaux, Ciseaux bat Feuille, Feuille bat
  Pierre. Egalite -> la manche est rejouee (aucun point). Premier a
  5 points gagne.

  Les 3 boutons de choix sont dessines en rendu "sub-pixel" via
  subpixel.lua (glyphes 0x80-0x9F de CC:Tweaked, grille 2x3 par
  case, quantification en espace Oklab) plutot qu'en aplat de
  couleur -- de vraies petites icones (rocher, feuille pliee,
  ciseaux) au lieu de blocs plats.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 1
local WIN_SCORE = 5

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

local CHOICES = { "rock", "paper", "scissors" }
local BEATS = { rock = "scissors", paper = "rock", scissors = "paper" }
local CHOICE_LABEL = { rock = "Pierre", paper = "Feuille", scissors = "Ciseaux" }

local function otherSide(side) return (side == "player1") and "player2" or "player1" end

local function newGame()
  return {
    choices = { player1 = nil, player2 = nil },
    ready = { player1 = false, player2 = false }, -- a tape "continuer" apres la revelation
    scores = { player1 = 0, player2 = 0 },
    roundResult = nil, -- nil (pas encore revele) | "player1" | "player2" | "draw"
    gameOver = false,
    winner = nil, -- "player1" | "player2"
  }
end

local function isValidChoice(c)
  for _, v in ipairs(CHOICES) do
    if v == c then return true end
  end
  return false
end

-- `side` choisit `choice` pour la manche en cours.
local function makeChoice(G, side, choice)
  if G.gameOver then return false end
  if G.roundResult then return false end -- manche deja revelee, pas de nouveau choix avant "continuer"
  if G.choices[side] then return false end -- deja choisi cette manche
  if not isValidChoice(choice) then return false end

  G.choices[side] = choice

  if G.choices.player1 and G.choices.player2 then
    -- les 2 ont choisi : revelation
    local c1, c2 = G.choices.player1, G.choices.player2
    if c1 == c2 then
      G.roundResult = "draw"
    elseif BEATS[c1] == c2 then
      G.roundResult = "player1"
      G.scores.player1 = G.scores.player1 + 1
    else
      G.roundResult = "player2"
      G.scores.player2 = G.scores.player2 + 1
    end

    if G.scores.player1 >= WIN_SCORE or G.scores.player2 >= WIN_SCORE then
      G.gameOver = true
      G.winner = (G.scores.player1 >= WIN_SCORE) and "player1" or "player2"
    end
  end

  return true
end

-- `side` confirme avoir vu le resultat de la manche et est pret pour
-- la suivante. Une fois les 2 prets, la manche suivante commence
-- (sauf si la partie est terminee).
local function confirmReady(G, side)
  if G.gameOver then return false end
  if not G.roundResult then return false end -- rien a confirmer si pas encore revele
  if G.ready[side] then return false end

  G.ready[side] = true

  if G.ready.player1 and G.ready.player2 then
    G.choices = { player1 = nil, player2 = nil }
    G.ready = { player1 = false, player2 = false }
    G.roundResult = nil
  end

  return true
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, side, action)
  if action.type == "choose" then
    makeChoice(G, side, action.choice)
    return G, false
  elseif action.type == "ready" then
    confirmReady(G, side)
    return G, false
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

_G.__rps_internal = {
  newGame = newGame,
  makeChoice = makeChoice,
  confirmReady = confirmReady,
  handleAction = handleAction,
  CHOICES = CHOICES,
  BEATS = BEATS,
  CHOICE_LABEL = CHOICE_LABEL,
  WIN_SCORE = WIN_SCORE,
}

if _G.__RPS_TEST_MODE then return end

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
local subpixel = dofile(resolveNear("subpixel.lua"))
local monitorCfg = monitorsLib.load(resolveNear(MONITORS_CONFIG_PATH))

local WALL_1_NAME = monitorCfg.player1
local WALL_2_NAME = monitorCfg.player2

local wall1 = peripheral.wrap(WALL_1_NAME)
local wall2 = peripheral.wrap(WALL_2_NAME)
for _, entry in ipairs({ { WALL_1_NAME, wall1 }, { WALL_2_NAME, wall2 } }) do
  if not entry[2] then
    error("Moniteur introuvable : '" .. entry[1] .. "' (defini dans " .. MONITORS_CONFIG_PATH .. ")")
  end
end
wall1.setTextScale(TEXT_SCALE)
wall2.setTextScale(TEXT_SCALE)

local SCREENS = {
  player1 = { mon = wall1, side = "player1" },
  player2 = { mon = wall2, side = "player2" },
}
local SCREEN_KEYS = { "player1", "player2" }
local NAME_TO_KEY = { [WALL_1_NAME] = "player1", [WALL_2_NAME] = "player2" }

-- ------------------------------------------------------------
-- Icones en pixel art (rendu sub-pixel, voir subpixel.lua)
-- ------------------------------------------------------------

local ICON_W, ICON_H = 16, 18 -- pixels -> 8x6 caracteres

local function buildRockIcon()
  local g = subpixel.newGrid(ICON_W, ICON_H, colors.black)
  local cx, cy, rx, ry = 8.5, 9.5, 7, 8
  for row = 1, ICON_H do
    for col = 1, ICON_W do
      local dx, dy = (col - cx) / rx, (row - cy) / ry
      if dx * dx + dy * dy <= 1 then
        g[row][col] = (dx < -0.15 and dy < -0.15) and colors.lightGray or colors.gray
      end
    end
  end
  return g
end

local function buildPaperIcon()
  local g = subpixel.newGrid(ICON_W, ICON_H, colors.black)
  for row = 2, 17 do
    for col = 3, 14 do
      g[row][col] = colors.white
    end
  end
  for i = 0, 3 do
    for j = 0, i do
      local r, c = 2 + j, 14 - i + j
      if g[r] and g[r][c] then g[r][c] = colors.lightGray end
    end
  end
  return g
end

local function buildScissorsIcon()
  local g = subpixel.newGrid(ICON_W, ICON_H, colors.black)
  for row = 1, 12 do
    local t = (row - 1) / 11
    local colA = math.floor(1 + t * 14 + 0.5)
    local colB = math.floor(16 - t * 14 + 0.5)
    for dc = 0, 1 do
      if g[row][colA + dc] then g[row][colA + dc] = colors.lightGray end
      if g[row][colB + dc] then g[row][colB + dc] = colors.lightGray end
    end
  end
  local function ring(cx, cy, r, color)
    for row = math.max(1, cy - r), math.min(ICON_H, cy + r) do
      for col = math.max(1, cx - r), math.min(ICON_W, cx + r) do
        local dx, dy = col - cx, row - cy
        if dx * dx + dy * dy <= r * r then g[row][col] = color end
      end
    end
  end
  ring(4, 15, 3, colors.red)
  ring(13, 15, 3, colors.blue)
  return g
end

local ICONS = { rock = buildRockIcon(), paper = buildPaperIcon(), scissors = buildScissorsIcon() }
local ICON_CHAR_W, ICON_CHAR_H = ICON_W / 2, ICON_H / 3 -- 8 x 6

-- ------------------------------------------------------------
-- Rendu
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

-- Dessine une icone + son libelle en dessous, et retourne la zone
-- cliquable englobante (icone + libelle).
local function drawChoiceButton(mon, x, y, choiceKey, clickable, dim)
  local icon = ICONS[choiceKey]
  if dim then
    -- version grisee (choix non disponible) : re-teinte tous les
    -- pixels non-noirs en gris, pour rester coherent avec le style
    -- "assombri" utilise partout ailleurs dans les autres jeux.
    local dimmed = subpixel.newGrid(ICON_W, ICON_H, colors.black)
    for row = 1, ICON_H do
      for col = 1, ICON_W do
        if icon[row][col] ~= colors.black then dimmed[row][col] = colors.gray end
      end
    end
    icon = dimmed
  end
  subpixel.draw(mon, x, y, icon, ICON_W, ICON_H)

  local labelY = y + ICON_CHAR_H
  mon.setCursorPos(x, labelY)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(dim and colors.gray or colors.white)
  local label = CHOICE_LABEL[choiceKey]
  local pad = ICON_CHAR_W - #label
  mon.write(string.rep(" ", math.max(0, math.floor(pad / 2))) .. label)
  mon.setTextColor(colors.white)

  if clickable then
    return { x1 = x, y1 = y, x2 = x + ICON_CHAR_W - 1, y2 = labelY, action = "choose", choice = choiceKey }
  end
  return nil
end

local function renderScreen(G, mon, side)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write(string.format("Toi: %d   Adversaire: %d   (premier a %d)",
    G.scores[side], G.scores[otherSide(side)], WIN_SCORE))

  if G.gameOver then
    mon.setCursorPos(1, 3)
    if G.winner == side then
      mon.setTextColor(colors.lime)
      mon.write("Tu as gagne la partie !")
    else
      mon.setTextColor(colors.red)
      mon.write("L'adversaire a gagne la partie...")
    end
    mon.setTextColor(colors.white)

    local by = 5
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, by, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = by, x2 = btnW, y2 = by, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, by, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = by, x2 = quitX + btnW - 1, y2 = by, action = "quit" }
    return clickZones
  end

  if G.roundResult then
    -- revelation : les 2 icones cote a cote + resultat
    mon.setCursorPos(1, 3)
    if G.roundResult == "draw" then
      mon.setTextColor(colors.yellow)
      mon.write("Egalite ! La manche est rejouee.")
    elseif G.roundResult == side then
      mon.setTextColor(colors.lime)
      mon.write("Tu remportes la manche !")
    else
      mon.setTextColor(colors.red)
      mon.write("L'adversaire remporte la manche...")
    end
    mon.setTextColor(colors.white)

    mon.setCursorPos(1, 5)
    mon.write("Toi :")
    drawChoiceButton(mon, 1, 6, G.choices[side], false, false)

    local oppX = ICON_CHAR_W + 4
    mon.setCursorPos(oppX, 5)
    mon.write("Adversaire :")
    drawChoiceButton(mon, oppX, 6, G.choices[otherSide(side)], false, false)

    local by = 6 + ICON_CHAR_H + 2
    if not G.ready[side] then
      drawButton(mon, 1, by, 16, "Manche suivante", colors.lime, colors.black)
      clickZones[#clickZones + 1] = { x1 = 1, y1 = by, x2 = 16, y2 = by, action = "ready" }
    else
      mon.setCursorPos(1, by)
      mon.setTextColor(colors.lightGray)
      mon.write("En attente de l'adversaire...")
      mon.setTextColor(colors.white)
    end
    return clickZones
  end

  if G.choices[side] then
    mon.setCursorPos(1, 3)
    mon.setTextColor(colors.lightGray)
    mon.write("Tu as choisi. En attente de l'adversaire...")
    mon.setTextColor(colors.white)
    mon.setCursorPos(1, 5)
    mon.write("Ton choix :")
    drawChoiceButton(mon, 1, 6, G.choices[side], false, false)
    return clickZones
  end

  -- rien choisi encore : les 3 boutons sont actifs
  mon.setCursorPos(1, 3)
  mon.setTextColor(colors.lime)
  mon.write("Fais ton choix !")
  mon.setTextColor(colors.white)

  local slotW = ICON_CHAR_W + 2
  local y = 5
  for i, choiceKey in ipairs(CHOICES) do
    local x = 1 + (i - 1) * slotW
    if x + ICON_CHAR_W - 1 <= w then
      local zone = drawChoiceButton(mon, x, y, choiceKey, true, false)
      if zone then clickZones[#clickZones + 1] = zone end
    end
  end

  return clickZones
end

local lastClickZones = { player1 = {}, player2 = {} }
_G.__RPS_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

local function redrawAll(G)
  for _, key in ipairs(SCREEN_KEYS) do
    local s = SCREENS[key]
    lastClickZones[key] = renderScreen(G, s.mon, s.side)
  end
end

local function zoneAt(zones, x, y)
  for _, z in ipairs(zones) do
    if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z end
  end
  return nil
end

local function zoneToAction(zone)
  if zone.action == "choose" then return { type = "choose", choice = zone.choice } end
  if zone.action == "ready" then return { type = "ready" } end
  if zone.action == "restart" then return { type = "restart" } end
  if zone.action == "quit" then return { type = "quit" } end
  return nil
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Pierre-Feuille-Ciseaux (2 joueurs) lance. Ctrl+T pour arreter.")

if _G.__RPS_AUTOPILOT then
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__RPS_AUTOPILOT_GAMES do
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
    if totalTurns > _G.__RPS_AUTOPILOT_GAMES * 3000 then
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
          print("Pierre-Feuille-Ciseaux ferme.")
          return
        end
        redrawAll(G)
      end
    end
  end
end