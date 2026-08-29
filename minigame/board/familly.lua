--[[
  familles_game.lua
  ---------------------------------------------------------------
  luaforcc :: Jeu des 7 familles -- theme langages de programmation.
  2 JOUEURS HUMAINS, 2 ecrans MURAUX prives (monitors.cfg lignes 1
  et 2, comme Uno) -- si les 2 moniteurs sont physiquement separes,
  chaque joueur ne voit jamais la main de l'autre. Pas d'ecran au
  sol necessaire.

  Familles = langages de programmation. Membres (theme des noms
  traditionnels du jeu -> concept technique) :
    fils       -> Constante
    fille      -> Variable
    pere       -> Fonction
    mere       -> Malloc
    grand-pere -> Classe
    grand-mere -> Struct

  7 familles x 6 membres = 42 cartes.

  Regles classiques du jeu des 7 familles (2 joueurs, avec pioche) :
    - 6 cartes distribuees a chacun au depart, le reste forme la
      pioche.
    - A ton tour, tu demandes a l'adversaire un membre PRECIS d'une
      famille dont tu as deja au moins une carte, et que tu n'as pas
      encore. S'il l'a, il te la donne et tu rejoues. Sinon, tu
      piochais : si la carte piochee est justement celle demandee,
      tu rejoues ; sinon, ton tour se termine.
    - Des qu'un joueur reunit les 6 membres d'une famille, elle est
      posee de son cote (definitivement gagnee).
    - La partie se termine quand les 7 familles ont ete reunies, ou
      qu'un joueur ne peut plus jouer (main et pioche vides a son
      tour, auquel cas il pioche gratuitement s'il le peut). Le plus
      de familles completes gagne.

  2 moniteurs muraux utilises (monitors.cfg lignes 1 et 2), scale
  0.5, pense pour des moniteurs de 4 blocs de large.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITORS_CONFIG_PATH = "monitors.cfg"
local TEXT_SCALE = 0.5

-- ============================================================
-- DONNEES : familles et membres
-- ============================================================

local FAMILIES = {
  "Python", "JavaScript", "Java", "C", "C++", "Rust", "Lua",
}

-- Table de correspondance (gardee pour reference / au cas ou) :
--   fils       -> Constante
--   fille      -> Variable
--   pere       -> Fonction
--   mere       -> Malloc
--   grand-pere -> Classe
--   grand-mere -> Struct
local MEMBERS = {
  "Constante", "Variable", "Fonction", "Malloc", "Classe", "Struct",
}

local SIDE_LABEL = { player1 = "Joueur 1", player2 = "Joueur 2" }

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

local function makeDeck()
  local deck = {}
  for f = 1, #FAMILIES do
    for m = 1, #MEMBERS do
      deck[#deck + 1] = { f = f, m = m }
    end
  end
  return deck
end

local function shuffle(list)
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

local function findCard(hand, f, m)
  for i, c in ipairs(hand) do
    if c.f == f and c.m == m then return i end
  end
  return nil
end

local function hasCard(hand, f, m)
  return findCard(hand, f, m) ~= nil
end

local function familiesOwned(hand)
  local seen = {}
  local list = {}
  for _, c in ipairs(hand) do
    if not seen[c.f] then
      seen[c.f] = true
      list[#list + 1] = c.f
    end
  end
  table.sort(list)
  return list
end

local function missingMembers(hand, f)
  local owned = {}
  for _, c in ipairs(hand) do
    if c.f == f then owned[c.m] = true end
  end
  local missing = {}
  for m = 1, #MEMBERS do
    if not owned[m] then missing[#missing + 1] = m end
  end
  return missing
end

local function otherSide(side) return (side == "player1") and "player2" or "player1" end

local function newGame()
  local deck = makeDeck()
  shuffle(deck)

  local hands = { player1 = {}, player2 = {} }
  for _ = 1, 6 do
    table.insert(hands.player1, table.remove(deck))
    table.insert(hands.player2, table.remove(deck))
  end

  return {
    hands = hands,
    pile = deck,
    completed = { player1 = {}, player2 = {} }, -- completed[side][f] = true
    completedCount = { player1 = 0, player2 = 0 },
    currentTurn = "player1",
    log = { "La partie commence ! Au tour de " .. SIDE_LABEL.player1 .. "." },
    gameOver = false,
    winner = nil, -- "player1" | "player2" | "draw"
  }
end

local LOG_LINES = 3

local function pushLog(G, msg)
  table.insert(G.log, msg)
  if #G.log > LOG_LINES then table.remove(G.log, 1) end
end

-- Retire de `hand` tous les membres de la famille `f` SI elle est
-- complete (6/6), et met a jour completed/completedCount. Retourne
-- true si la famille vient d'etre completee.
local function checkCompletion(G, side, f)
  local hand = G.hands[side]
  local count = 0
  for _, c in ipairs(hand) do
    if c.f == f then count = count + 1 end
  end
  if count == #MEMBERS then
    for i = #hand, 1, -1 do
      if hand[i].f == f then table.remove(hand, i) end
    end
    G.completed[side][f] = true
    G.completedCount[side] = G.completedCount[side] + 1
    pushLog(G, SIDE_LABEL[side] .. " remporte la famille " .. FAMILIES[f] .. " !")
    return true
  end
  return false
end

local function canAnyonePlay(G, side)
  return #G.hands[side] > 0 or #G.pile > 0
end

-- Si `side` se retrouve avec une main vide alors que c'est (ou va
-- etre) son tour, il pioche une carte gratuite pour pouvoir
-- continuer a jouer (sinon il resterait bloque a vie, incapable de
-- demander quoi que ce soit puisqu'il faut posseder au moins une
-- carte d'une famille pour en demander une autre).
local function ensureCanAct(G, side)
  if #G.hands[side] == 0 and #G.pile > 0 then
    local drawn = table.remove(G.pile)
    table.insert(G.hands[side], drawn)
    pushLog(G, SIDE_LABEL[side] .. " n'avait plus de carte : pioche gratuite pour continuer.")
    checkCompletion(G, side, drawn.f)
  end
end

local function checkGameEnd(G)
  if G.completedCount.player1 + G.completedCount.player2 >= #FAMILIES then
    G.gameOver = true
  else
    ensureCanAct(G, G.currentTurn)
    if not canAnyonePlay(G, G.currentTurn) then
      G.gameOver = true
    end
  end
  if G.gameOver then
    if G.completedCount.player1 > G.completedCount.player2 then
      G.winner = "player1"
    elseif G.completedCount.player2 > G.completedCount.player1 then
      G.winner = "player2"
    else
      G.winner = "draw"
    end
  end
end

-- `asker` demande a l'autre le membre (f,m). Doit avoir au moins 1
-- carte de la famille f et NE PAS deja avoir (f,m).
local function askCard(G, asker, f, m)
  if G.gameOver then return false end
  if G.currentTurn ~= asker then return false end
  local hand = G.hands[asker]
  local ownsFamily = false
  for _, c in ipairs(hand) do
    if c.f == f then ownsFamily = true break end
  end
  if not ownsFamily then return false end
  if hasCard(hand, f, m) then return false end

  local target = otherSide(asker)
  local famName, memName = FAMILIES[f], MEMBERS[m]
  local idx = findCard(G.hands[target], f, m)
  local askerLabel = SIDE_LABEL[asker]

  if idx then
    table.remove(G.hands[target], idx)
    table.insert(hand, { f = f, m = m })
    pushLog(G, askerLabel .. " demande " .. memName .. " (" .. famName ..
      ") -- carte obtenue, rejoue !")
    checkCompletion(G, asker, f)
    -- rejoue : currentTurn ne change pas
  else
    if #G.pile > 0 then
      local drawn = table.remove(G.pile)
      table.insert(hand, drawn)
      -- important : on verifie la completion de la famille de la
      -- carte REELLEMENT piochee (drawn.f), pas celle qui a ete
      -- demandee (f) -- une pioche "hors sujet" peut tres bien
      -- completer une AUTRE famille que celle visee.
      checkCompletion(G, asker, drawn.f)
      if drawn.f == f and drawn.m == m then
        pushLog(G, askerLabel .. " demande " .. memName .. " (" .. famName ..
          ") -- pioche justement cette carte, rejoue !")
        -- rejoue
      else
        pushLog(G, askerLabel .. " demande " .. memName .. " (" .. famName ..
          ") -- pioche une autre carte, tour termine.")
        G.currentTurn = target
      end
    else
      pushLog(G, askerLabel .. " demande " .. memName .. " (" .. famName ..
        ") -- pioche vide, tour termine.")
      G.currentTurn = target
    end
  end

  checkGameEnd(G)
  return true
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, side, action)
  if action.type == "ask" then
    askCard(G, side, action.f, action.m)
    return G, false
  elseif action.type == "restart" then
    return newGame(), false
  elseif action.type == "quit" then
    return G, true
  end
  return G, false
end

_G.__familles_internal = {
  newGame = newGame,
  askCard = askCard,
  familiesOwned = familiesOwned,
  missingMembers = missingMembers,
  hasCard = hasCard,
  checkCompletion = checkCompletion,
  ensureCanAct = ensureCanAct,
  handleAction = handleAction,
  makeDeck = makeDeck,
  FAMILIES = FAMILIES,
  MEMBERS = MEMBERS,
}

if _G.__FAMILLES_TEST_MODE then return end

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
-- Rendu -- cartes "posters" avec bandeau de couleur par famille,
-- plus pousse que le style Uno (simple bloc colore + etiquette).
-- ------------------------------------------------------------

local FAMILY_COLORS = {
  colors.blue, colors.yellow, colors.orange, colors.lightGray,
  colors.magenta, colors.brown, colors.cyan,
}

local CARD_W, CARD_H = 16, 5

local function drawCard(mon, x, y, f, m, opts)
  opts = opts or {}
  local dim = opts.dim
  local color = dim and colors.gray or FAMILY_COLORS[f]
  local borderFg = dim and colors.gray or colors.white
  local famName = FAMILIES[f]
  local memName = m and MEMBERS[m] or nil

  local function centered(text, width)
    text = text or ""
    if #text > width then text = text:sub(1, width) end
    local pad = width - #text
    local left = math.floor(pad / 2)
    return string.rep(" ", left) .. text .. string.rep(" ", pad - left)
  end

  mon.setBackgroundColor(colors.black)
  mon.setTextColor(borderFg)
  mon.setCursorPos(x, y)
  mon.write("+" .. string.rep("-", CARD_W - 2) .. "+")

  mon.setCursorPos(x, y + 1)
  mon.write("|")
  mon.setBackgroundColor(color)
  mon.setTextColor(dim and colors.lightGray or colors.black)
  mon.write(centered(famName, CARD_W - 2))
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(borderFg)
  mon.write("|")

  mon.setCursorPos(x, y + 2)
  mon.write("|" .. string.rep(" ", CARD_W - 2) .. "|")

  mon.setCursorPos(x, y + 3)
  mon.write("|")
  mon.setTextColor(dim and colors.gray or colors.white)
  mon.write(centered(memName, CARD_W - 2))
  mon.setTextColor(borderFg)
  mon.write("|")

  mon.setCursorPos(x, y + 4)
  mon.write("+" .. string.rep("-", CARD_W - 2) .. "+")

  mon.setTextColor(colors.white)
  mon.setBackgroundColor(colors.black)
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

-- askPhase[side] = nil, ou { family = f } quand ce joueur est en
-- train de choisir le membre a demander. Etat purement UI, prive a
-- chaque ecran (independant l'un de l'autre).
local askPhase = { player1 = nil, player2 = nil }

local function renderScreen(G, mon, side)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}
  local myTurn = (not G.gameOver) and G.currentTurn == side

  -- entete : score + statut
  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write(string.format("Familles completes -- Toi: %d   Adversaire: %d   Pioche: %d",
    G.completedCount[side], G.completedCount[otherSide(side)], #G.pile))

  mon.setCursorPos(1, 2)
  if G.gameOver then
    if G.winner == side then
      mon.setTextColor(colors.lime)
      mon.write("Tu as gagne !")
    elseif G.winner == "draw" then
      mon.setTextColor(colors.white)
      mon.write("Match nul !")
    else
      mon.setTextColor(colors.red)
      mon.write("Tu as perdu...")
    end
  elseif myTurn then
    mon.setTextColor(colors.lime)
    mon.write("A toi de jouer -- choisis une carte de ta main")
  else
    mon.setTextColor(colors.lightGray)
    mon.write("Tour de l'adversaire...")
  end
  mon.setTextColor(colors.white)

  -- journal des dernieres actions -- hauteur TOUJOURS FIXE (LOG_LINES
  -- lignes) : sinon la mise en page se resserre au fil de la partie
  -- et finit par repousser les cartes hors de l'ecran.
  local logY = 4
  mon.setCursorPos(1, logY)
  mon.setTextColor(colors.lightGray)
  mon.write("Journal :")
  for i = 1, LOG_LINES do
    local line = G.log[#G.log - LOG_LINES + i]
    if line then
      mon.setCursorPos(1, logY + i)
      mon.write("- " .. line)
    end
  end
  mon.setTextColor(colors.white)

  local afterLogY = logY + LOG_LINES + 2

  if G.gameOver then
    local btnW = math.max(6, math.min(15, math.floor((w - 1) / 2)))
    drawButton(mon, 1, afterLogY, btnW, "Rejouer", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = afterLogY, x2 = btnW, y2 = afterLogY, action = "restart" }
    local quitX = btnW + 2
    drawButton(mon, quitX, afterLogY, btnW, "Quitter", colors.red, colors.white)
    clickZones[#clickZones + 1] = { x1 = quitX, y1 = afterLogY, x2 = quitX + btnW - 1, y2 = afterLogY, action = "quit" }
    return clickZones
  end

  local cols = math.max(1, math.floor(w / (CARD_W + 1)))
  local phase = askPhase[side]

  if myTurn and phase then
    -- phase 2 : choix du membre a demander dans la famille selectionnee.
    -- Le bouton Annuler est place a une position FIXE (juste apres le
    -- titre), toujours atteignable meme si la grille en dessous
    -- deborde. Seuls les membres MANQUANTS (cliquables) sont mis dans
    -- la grille -- les membres deja possedes ne reservent pas de
    -- place pour rien.
    local f = phase.family
    mon.setCursorPos(1, afterLogY)
    mon.setTextColor(colors.white)
    mon.write("Famille " .. FAMILIES[f] .. " -- quel membre demander ?")

    local cancelY = afterLogY + 1
    drawButton(mon, 1, cancelY, 14, "Annuler", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = cancelY, x2 = 14, y2 = cancelY, action = "cancel" }

    local missing = missingMembers(G.hands[side], f)
    local gridY = cancelY + 2
    for i, m in ipairs(missing) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local x = 1 + col * (CARD_W + 1)
      local y = gridY + row * (CARD_H + 1)
      if y + CARD_H - 1 <= h then
        drawCard(mon, x, y, f, m, {})
        clickZones[#clickZones + 1] = {
          x1 = x, y1 = y, x2 = x + CARD_W - 1, y2 = y + CARD_H - 1, action = "ask", f = f, m = m,
        }
      end
    end
  else
    -- phase 1 : ta main -- tape une carte pour choisir sa famille
    mon.setCursorPos(1, afterLogY)
    mon.setTextColor(colors.lightGray)
    mon.write("Ta main (" .. #G.hands[side] .. ") :")
    mon.setTextColor(colors.white)

    local hand = {}
    for i, c in ipairs(G.hands[side]) do hand[i] = c end
    table.sort(hand, function(a, b)
      if a.f ~= b.f then return a.f < b.f end
      return a.m < b.m
    end)

    local gridY = afterLogY + 2
    for i, c in ipairs(hand) do
      local col = (i - 1) % cols
      local row = math.floor((i - 1) / cols)
      local x = 1 + col * (CARD_W + 1)
      local y = gridY + row * (CARD_H + 1)
      if y + CARD_H - 1 <= h then
        drawCard(mon, x, y, c.f, c.m, {})
        if myTurn then
          clickZones[#clickZones + 1] = {
            x1 = x, y1 = y, x2 = x + CARD_W - 1, y2 = y + CARD_H - 1, action = "pickFamily", f = c.f,
          }
        end
      end
    end
  end

  return clickZones
end

local lastClickZones = { player1 = {}, player2 = {} }
_G.__FAMILLES_DEBUG_ZONES = function() return lastClickZones end -- hook de test, sans effet en jeu

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
  if zone.action == "ask" then return { type = "ask", f = zone.f, m = zone.m } end
  if zone.action == "restart" then return { type = "restart" } end
  if zone.action == "quit" then return { type = "quit" } end
  return nil
end

-- Applique une zone cliquee sur l'ecran de `side`. Gere aussi les
-- actions purement UI (pickFamily/cancel) qui ne passent pas par le
-- moteur.
local function applyZone(G, side, zone)
  if zone.action == "pickFamily" then
    askPhase[side] = { family = zone.f }
    return G, false
  elseif zone.action == "cancel" then
    askPhase[side] = nil
    return G, false
  end
  local action = zoneToAction(zone)
  if not action then return G, false end
  local quit
  G, quit = handleAction(G, side, action)
  if action.type == "ask" or action.type == "restart" then
    askPhase.player1 = nil
    askPhase.player2 = nil
  end
  return G, quit
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Jeu des 7 familles (2 joueurs) lance sur " .. WALL_1_NAME .. " / " .. WALL_2_NAME .. ". Ctrl+T pour arreter.")

if _G.__FAMILLES_AUTOPILOT then
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__FAMILLES_AUTOPILOT_GAMES do
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
    local quit
    G, quit = applyZone(G, key, chosen)
    redrawAll(G)
    totalTurns = totalTurns + 1
    if chosen.action == "restart" then gamesPlayed = gamesPlayed + 1 end
    if totalTurns > _G.__FAMILLES_AUTOPILOT_GAMES * 3000 then
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
      local quit
      G, quit = applyZone(G, key, zone)
      if quit then
        for _, k in ipairs(SCREEN_KEYS) do
          local mon = SCREENS[k].mon
          mon.setBackgroundColor(colors.black)
          mon.clear()
        end
        print("Jeu des 7 familles ferme.")
        return
      end
      redrawAll(G)
    end
  end
end