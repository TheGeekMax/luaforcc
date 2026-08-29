--[[
  familles_game.lua
  ---------------------------------------------------------------
  luaforcc :: Jeu des 7 familles -- theme langages de programmation.
  Solo contre une IA, sur UN SEUL ecran (le mural, monitors.cfg
  ligne 1). Pas besoin d'un 2e ecran : la main de l'IA n'a jamais
  besoin d'etre affichee, donc pas de probleme de secret a gerer.

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
      tour). Le plus de familles completes gagne.

  Un seul moniteur utilise (monitors.cfg ligne 1), scale 0.5, pense
  pour un moniteur de 4 blocs de large.
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

local function otherSide(side) return (side == "player") and "bot" or "player" end

local function newGame()
  local deck = makeDeck()
  shuffle(deck)

  local hands = { player = {}, bot = {} }
  for _ = 1, 6 do
    table.insert(hands.player, table.remove(deck))
    table.insert(hands.bot, table.remove(deck))
  end

  return {
    hands = hands,
    pile = deck,
    completed = { player = {}, bot = {} }, -- completed[side][f] = true
    completedCount = { player = 0, bot = 0 },
    currentTurn = "player",
    log = { "La partie commence ! A toi de jouer." },
    gameOver = false,
    winner = nil, -- "player" | "bot" | "draw"
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
    pushLog(G, (side == "player")
      and "Ta main etait vide : tu piochais une carte gratuite pour continuer."
      or "L'IA n'avait plus de carte : elle en pioche une gratuitement.")
    checkCompletion(G, side, drawn.f)
  end
end

local function checkGameEnd(G)
  if G.completedCount.player + G.completedCount.bot >= #FAMILIES then
    G.gameOver = true
  else
    ensureCanAct(G, G.currentTurn)
    if not canAnyonePlay(G, G.currentTurn) then
      G.gameOver = true
    end
  end
  if G.gameOver then
    if G.completedCount.player > G.completedCount.bot then
      G.winner = "player"
    elseif G.completedCount.bot > G.completedCount.player then
      G.winner = "bot"
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

  if idx then
    table.remove(G.hands[target], idx)
    table.insert(hand, { f = f, m = m })
    pushLog(G, (asker == "player" and "Tu demandes" or "L'IA demande") ..
      " " .. memName .. " (" .. famName .. ") -- carte obtenue, rejoue !")
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
      local completed = checkCompletion(G, asker, drawn.f)
      if drawn.f == f and drawn.m == m then
        pushLog(G, (asker == "player" and "Tu demandes" or "L'IA demande") ..
          " " .. memName .. " (" .. famName .. ") -- pioche justement cette carte, rejoue !")
        -- rejoue
      else
        pushLog(G, (asker == "player" and "Tu demandes" or "L'IA demande") ..
          " " .. memName .. " (" .. famName .. ") -- pioche une autre carte, tour termine.")
        G.currentTurn = target
      end
    else
      pushLog(G, (asker == "player" and "Tu demandes" or "L'IA demande") ..
        " " .. memName .. " (" .. famName .. ") -- pioche vide, tour termine.")
      G.currentTurn = target
    end
  end

  checkGameEnd(G)
  return true
end

-- Joue le tour de l'IA jusqu'a ce que ce ne soit plus a elle de
-- jouer (echec/pioche ratee) ou fin de partie. Entierement
-- automatique : aucune interaction utilisateur necessaire.
-- Robuste par elle-meme (n'attend pas que l'appelant ait deja garanti
-- que l'IA peut agir) : elle regle ce cas via ensureCanAct/checkGameEnd.
local function processBotTurn(G)
  local safety = 0
  while not G.gameOver and G.currentTurn == "bot" do
    safety = safety + 1
    if safety > 200 then break end -- garde-fou, ne devrait jamais arriver

    local owned = familiesOwned(G.hands.bot)
    if #owned == 0 then
      ensureCanAct(G, "bot")
      owned = familiesOwned(G.hands.bot)
      if #owned == 0 then
        -- toujours rien (pioche vide aussi) : fin de partie propre
        checkGameEnd(G)
        break
      end
    end
    local f = owned[math.random(#owned)]
    local missing = missingMembers(G.hands.bot, f)
    if #missing == 0 then
      -- ne devrait pas arriver (une famille complete est retiree de
      -- la main), garde-fou
      break
    end
    local m = missing[math.random(#missing)]
    local ok = askCard(G, "bot", f, m)
    if not ok then break end
  end
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

local function handleAction(G, action)
  if action.type == "ask" then
    local ok = askCard(G, "player", action.f, action.m)
    if ok and not G.gameOver and G.currentTurn == "bot" then
      processBotTurn(G)
    end
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
  processBotTurn = processBotTurn,
  familiesOwned = familiesOwned,
  missingMembers = missingMembers,
  hasCard = hasCard,
  checkCompletion = checkCompletion,
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
local MONITOR_NAME = monitorCfg.player1 -- seul l'ecran "joueur 1" (mural) est utilise

local mon = peripheral.wrap(MONITOR_NAME)
if not mon then
  error("Moniteur introuvable : '" .. MONITOR_NAME .. "' (defini dans " .. MONITORS_CONFIG_PATH .. ")")
end
mon.setTextScale(TEXT_SCALE)

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

local askPhase = nil -- nil, ou { family = f } quand on choisit le membre a demander

local function renderScreen(G)
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  -- entete : score + statut
  mon.setCursorPos(1, 1)
  mon.setTextColor(colors.white)
  mon.write(string.format("Familles completes -- Toi: %d   IA: %d   Pioche: %d",
    G.completedCount.player, G.completedCount.bot, #G.pile))

  mon.setCursorPos(1, 2)
  if G.gameOver then
    if G.winner == "player" then
      mon.setTextColor(colors.lime)
      mon.write("Tu as gagne !")
    elseif G.winner == "bot" then
      mon.setTextColor(colors.red)
      mon.write("L'IA a gagne...")
    else
      mon.setTextColor(colors.white)
      mon.write("Match nul !")
    end
  else
    mon.setTextColor(colors.lightGray)
    mon.write("A toi de jouer -- choisis une carte de ta main pour demander la suite de sa famille")
  end
  mon.setTextColor(colors.white)

  -- journal des dernieres actions -- hauteur TOUJOURS FIXE (LOG_LINES
  -- lignes, quel que soit le nombre d'entrees reellement presentes) :
  -- sinon la mise en page se resserre au fil de la partie et finit
  -- par repousser les cartes hors de l'ecran.
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

  if askPhase then
    -- phase 2 : choix du membre a demander dans la famille selectionnee.
    -- Le bouton Annuler est place a une position FIXE (juste apres le
    -- titre), toujours atteignable meme si la grille en dessous
    -- deborde. Seuls les membres MANQUANTS (cliquables) sont mis dans
    -- la grille -- les membres deja possedes ne reservent pas de
    -- place pour rien.
    local f = askPhase.family
    mon.setCursorPos(1, afterLogY)
    mon.setTextColor(colors.white)
    mon.write("Famille " .. FAMILIES[f] .. " -- quel membre demander ?")

    local cancelY = afterLogY + 1
    drawButton(mon, 1, cancelY, 14, "Annuler", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = cancelY, x2 = 14, y2 = cancelY, action = "cancel" }

    local missing = missingMembers(G.hands.player, f)
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
    mon.write("Ta main (" .. #G.hands.player .. ") :")
    mon.setTextColor(colors.white)

    local hand = {}
    for i, c in ipairs(G.hands.player) do hand[i] = c end
    table.sort(hand, function(a, b)
      if a.f ~= b.f then return a.f < b.f end
      return a.m < b.m
    end)

    local gridY = afterLogY + 2
    local myTurn = (not G.gameOver) and G.currentTurn == "player"
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

local lastClickZones = {}
_G.__FAMILLES_DEBUG_ZONES = function() return lastClickZones end

local function redraw(G)
  lastClickZones = renderScreen(G)
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
redraw(G)
print("Jeu des 7 familles lance sur " .. MONITOR_NAME .. ". Ctrl+T pour arreter.")

local function zoneToAction(zone)
  if zone.action == "pickFamily" then return { special = "pickFamily", f = zone.f } end
  if zone.action == "ask" then return { type = "ask", f = zone.f, m = zone.m } end
  if zone.action == "cancel" then return { special = "cancel" } end
  if zone.action == "restart" then return { type = "restart" } end
  if zone.action == "quit" then return { type = "quit" } end
  return nil
end

local function applyZone(G, zone)
  local action = zoneToAction(zone)
  if not action then return G, false end
  if action.special == "pickFamily" then
    askPhase = { family = action.f }
    return G, false
  elseif action.special == "cancel" then
    askPhase = nil
    return G, false
  end
  local quit
  G, quit = handleAction(G, action)
  if action.type == "ask" or action.type == "restart" then askPhase = nil end
  return G, quit
end

if _G.__FAMILLES_AUTOPILOT then
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__FAMILLES_AUTOPILOT_GAMES do
    if #lastClickZones == 0 then
      error("Aucune zone cliquable -- deadlock UI possible")
    end
    local chosen = lastClickZones[math.random(#lastClickZones)]
    local quit
    G, quit = applyZone(G, chosen)
    redraw(G)
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
  if side == MONITOR_NAME then
    local zone = zoneAt(lastClickZones, x, y)
    if zone then
      local quit
      G, quit = applyZone(G, zone)
      if quit then
        mon.setBackgroundColor(colors.black)
        mon.clear()
        print("Jeu des 7 familles ferme.")
        return
      end
      redraw(G)
    end
  end
end