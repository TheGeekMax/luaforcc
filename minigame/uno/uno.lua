--[[
  uno_game.lua
  ---------------------------------------------------------------
  luaforcc :: Uno 2 joueurs sur 2 moniteurs (main secrete par ecran)

  Config : les 2 moniteurs sont identifies par leur nom de
  peripherique (modifiable en haut de ce fichier). Chaque moniteur
  n'affiche QUE la main du joueur qui lui est assigne -- si les 2
  moniteurs sont physiquement separes (pieces differentes), chaque
  joueur ne voit jamais la main de l'autre.

  Regles : Uno classique complet (skip / reverse / +2 / wild /
  wild+4), avec ces choix/simplifications assumes :
    - Reverse et Skip ont le meme effet a 2 joueurs (le joueur en
      cours rejoue).
    - +2 et +4 : l'adversaire pioche puis passe son tour (donc le
      joueur en cours rejoue aussi).
    - Wild+4 n'est jouable QUE si aucune autre carte de la main ne
      correspond a la couleur en cours (regle officielle), mais SANS
      mecanique de "challenge" (pas de contestation possible).
    - Carte de depart : si c'est une carte speciale, son effet est
      ignore pour l'ouverture (le joueur 1 commence toujours). Si
      c'est un Wild+4, on la remet dans le paquet et on en retire
      une autre.
    - Piocher n'est permis QUE si le joueur n'a aucun coup jouable.
      Si la carte piochee est jouable, elle est jouee IMMEDIATEMENT
      (regle demandee) ; sinon le tour passe.
    - Pas de regle "dire Uno" : juste un indicateur visuel a 1 carte,
      sans penalite si non signale.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local MONITOR_1_NAME = "monitor_1"
local MONITOR_2_NAME = "monitor_2"
local TEXT_SCALE = 0.5

math.randomseed(os.epoch and os.epoch("utc") or os.time())

-- ============================================================
-- MOTEUR DE JEU (pur -- aucune dependance a l'affichage/peripheriques)
-- ============================================================

local COLORS = { "red", "yellow", "green", "blue" }

local function makeDeck()
  local deck = {}
  for _, c in ipairs(COLORS) do
    deck[#deck + 1] = { color = c, value = 0 }
    for v = 1, 9 do
      deck[#deck + 1] = { color = c, value = v }
      deck[#deck + 1] = { color = c, value = v }
    end
    for _ = 1, 2 do
      deck[#deck + 1] = { color = c, value = "skip" }
      deck[#deck + 1] = { color = c, value = "reverse" }
      deck[#deck + 1] = { color = c, value = "draw2" }
    end
  end
  for _ = 1, 4 do
    deck[#deck + 1] = { color = "wild", value = "wild" }
    deck[#deck + 1] = { color = "wild", value = "wild4" }
  end
  return deck
end

local function shuffle(list)
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

local function cardLabel(card)
  if card.value == "skip" then return "SK" end
  if card.value == "reverse" then return "RV" end
  if card.value == "draw2" then return "+2" end
  if card.value == "wild" then return "WD" end
  if card.value == "wild4" then return "W4" end
  return tostring(card.value)
end

-- Nouvel etat de jeu complet
local function newGame()
  local deck = makeDeck()
  shuffle(deck)

  local G = {
    drawPile = deck,
    discardPile = {},
    hands = { {}, {} }, -- index 1 = joueur 1, index 2 = joueur 2
    currentColor = nil,
    currentPlayer = 1,
    pendingColorChoice = false, -- vrai si le joueur courant doit choisir une couleur
    gameOver = false,
    winner = nil,
    message = "", -- petit texte d'evenement pour l'UI ("Joueur 1 pioche 2 cartes", etc.)
  }

  for _ = 1, 7 do
    table.insert(G.hands[1], table.remove(G.drawPile))
    table.insert(G.hands[2], table.remove(G.drawPile))
  end

  -- carte de depart : jamais un Wild+4 (on le remet et re-pioche)
  local starter
  repeat
    starter = table.remove(G.drawPile)
    if starter.value == "wild4" then
      table.insert(G.drawPile, 1, starter)
      shuffle(G.drawPile)
      starter = nil
    end
  until starter
  table.insert(G.discardPile, starter)
  G.currentColor = (starter.color ~= "wild") and starter.color or COLORS[math.random(#COLORS)]

  return G
end

local function topCard(G)
  return G.discardPile[#G.discardPile]
end

local function reshuffleIfNeeded(G)
  if #G.drawPile == 0 then
    local top = table.remove(G.discardPile) -- garde la carte du dessus
    G.drawPile = G.discardPile
    G.discardPile = { top }
    shuffle(G.drawPile)
  end
end

local function drawN(G, playerIndex, n)
  for _ = 1, n do
    reshuffleIfNeeded(G)
    if #G.drawPile > 0 then
      table.insert(G.hands[playerIndex], table.remove(G.drawPile))
    end
  end
end

-- Une carte de la main `hand` (a l'exclusion de `excludeIdx`) correspond-elle a `color` ?
local function handHasColor(hand, color, excludeIdx)
  for i, c in ipairs(hand) do
    if i ~= excludeIdx and c.color == color then return true end
  end
  return false
end

local function isPlayable(card, G, hand, cardIdxInHand)
  if card.value == "wild" then return true end
  if card.value == "wild4" then
    return not handHasColor(hand, G.currentColor, cardIdxInHand)
  end
  local top = topCard(G)
  return card.color == G.currentColor or card.value == top.value
end

local function hasLegalMove(G, playerIndex)
  local hand = G.hands[playerIndex]
  for i, c in ipairs(hand) do
    if isPlayable(c, G, hand, i) then return true end
  end
  return false
end

local function otherPlayer(p) return (p == 1) and 2 or 1 end

local function checkWin(G, playerIndex)
  if #G.hands[playerIndex] == 0 then
    G.gameOver = true
    G.winner = playerIndex
    return true
  end
  return false
end

-- Applique l'effet d'une carte QUI VIENT D'ETRE POSEE (deja retiree de
-- la main, deja au sommet de la defausse). `chosenColor` requis pour
-- les wild/wild4. Ne s'occupe PAS de choisir la couleur : c'est
-- `applyPlay` qui gere l'attente de choix si necessaire.
local function resolveEffect(G, playerIndex, card, chosenColor)
  local opponent = otherPlayer(playerIndex)

  if card.color == "wild" then
    G.currentColor = chosenColor
  else
    G.currentColor = card.color
  end

  if card.value == "skip" or card.value == "reverse" then
    G.message = "Carte speciale : le joueur " .. playerIndex .. " rejoue."
    G.currentPlayer = playerIndex
  elseif card.value == "draw2" then
    drawN(G, opponent, 2)
    G.message = "Joueur " .. opponent .. " pioche 2 cartes et passe son tour."
    G.currentPlayer = playerIndex
  elseif card.value == "wild4" then
    drawN(G, opponent, 4)
    G.message = "Joueur " .. opponent .. " pioche 4 cartes et passe son tour."
    G.currentPlayer = playerIndex
  else
    G.currentPlayer = opponent
  end
end

-- Joue la carte a l'index `cardIdx` de la main de `playerIndex`.
-- Si c'est un wild ET qu'aucune couleur n'est fournie, la fonction
-- met la partie en attente de choix de couleur (le coup sera
-- resolu par resolvePendingColorChoice) plutot que d'echouer.
-- Retourne true si le coup a ete accepte (joue ou mis en attente).
local function applyPlay(G, playerIndex, cardIdx, chosenColor)
  if G.gameOver or G.pendingColorChoice then return false end
  if G.currentPlayer ~= playerIndex then return false end
  local hand = G.hands[playerIndex]
  local card = hand[cardIdx]
  if not card then return false end
  if not isPlayable(card, G, hand, cardIdx) then return false end

  if card.color == "wild" and not chosenColor then
    G.pendingColorChoice = true
    G._pendingPlayIdx = cardIdx
    return true
  end

  table.remove(hand, cardIdx)
  table.insert(G.discardPile, card)

  if checkWin(G, playerIndex) then
    G.currentColor = (card.color ~= "wild") and card.color or chosenColor
    return true
  end

  resolveEffect(G, playerIndex, card, chosenColor)
  return true
end

-- Pioche pour `playerIndex` (uniquement autorise s'il n'a aucun coup
-- jouable). Si la carte piochee est jouable, elle est auto-jouee :
-- si c'est un wild, la fonction retourne needsColorChoice=true et
-- attend un appel a resolvePendingColorChoice.
local function applyDraw(G, playerIndex)
  if G.gameOver or G.pendingColorChoice then return false end
  if G.currentPlayer ~= playerIndex then return false end
  if hasLegalMove(G, playerIndex) then return false end

  reshuffleIfNeeded(G)
  if #G.drawPile == 0 then
    -- plus aucune carte nulle part (cas extreme) : le tour passe
    G.currentPlayer = otherPlayer(playerIndex)
    G.message = "Plus aucune carte a piocher : le tour passe."
    return true
  end

  local card = table.remove(G.drawPile)
  local hand = G.hands[playerIndex]
  table.insert(hand, card)
  local idx = #hand

  if isPlayable(card, G, hand, idx) then
    table.remove(hand, idx)
    table.insert(G.discardPile, card)
    G.message = "Carte piochee jouable : jouee automatiquement."

    if checkWin(G, playerIndex) then
      if card.color ~= "wild" then G.currentColor = card.color end
      return true
    end

    if card.color == "wild" then
      G.pendingColorChoice = true
      G.currentPlayer = playerIndex -- reste en attente du choix de couleur
      G._pendingWildCard = card -- info interne pour resolveEffect differe
    else
      resolveEffect(G, playerIndex, card, nil)
    end
  else
    G.message = "Carte piochee non jouable : le tour passe."
    G.currentPlayer = otherPlayer(playerIndex)
  end

  return true
end

-- A appeler quand G.pendingColorChoice est vrai, avec la couleur
-- choisie par le joueur courant. Gere 2 cas : une carte piochee et
-- auto-jouee (deja retiree de la main, stockee dans _pendingWildCard),
-- ou une carte wild choisie depuis la main (encore en main, retiree ici).
local function resolvePendingColorChoice(G, playerIndex, chosenColor)
  if not G.pendingColorChoice then return false end
  if G.currentPlayer ~= playerIndex then return false end

  if G._pendingPlayIdx then
    local hand = G.hands[playerIndex]
    local card = table.remove(hand, G._pendingPlayIdx)
    G._pendingPlayIdx = nil
    G.pendingColorChoice = false
    table.insert(G.discardPile, card)
    if checkWin(G, playerIndex) then
      G.currentColor = chosenColor
      return true
    end
    resolveEffect(G, playerIndex, card, chosenColor)
    return true
  end

  local card = G._pendingWildCard
  G._pendingWildCard = nil
  G.pendingColorChoice = false
  resolveEffect(G, playerIndex, card, chosenColor)
  return true
end

-- ============================================================
-- Hook de test interne (sans effet en jeu normal)
-- ============================================================

_G.__uno_internal = {
  newGame = newGame,
  applyPlay = applyPlay,
  applyDraw = applyDraw,
  resolvePendingColorChoice = resolvePendingColorChoice,
  hasLegalMove = hasLegalMove,
  isPlayable = isPlayable,
  topCard = topCard,
  cardLabel = cardLabel,
  COLORS = COLORS,
}

if _G.__UNO_TEST_MODE then return end

-- ============================================================
-- A PARTIR D'ICI : peripheriques, rendu, boucle de jeu
-- (non charge en mode test)
-- ============================================================

local mon1 = peripheral.wrap(MONITOR_1_NAME)
local mon2 = peripheral.wrap(MONITOR_2_NAME)
if not mon1 or not mon2 then
  error("Moniteurs introuvables. Verifie MONITOR_1_NAME/MONITOR_2_NAME en haut du script.")
end

mon1.setTextScale(TEXT_SCALE)
mon2.setTextScale(TEXT_SCALE)

local monitors = { mon1, mon2 } -- monitors[1] = ecran du joueur 1, monitors[2] = ecran du joueur 2

local CARD_COLOR_MAP = {
  red = colors.red,
  yellow = colors.yellow,
  green = colors.green,
  blue = colors.blue,
  wild = colors.gray,
}

local function textColorFor(bg)
  if bg == colors.yellow or bg == colors.white then return colors.black end
  return colors.white
end

-- ------------------------------------------------------------
-- Dessin d'une carte (rectangle 4 large x 3 haut + libelle centre)
-- ------------------------------------------------------------
local CARD_W, CARD_H = 4, 3

local function drawCard(mon, x, y, card, dim, w, h)
  w = w or CARD_W
  h = h or CARD_H
  local bg = CARD_COLOR_MAP[card.color] or colors.gray
  local fg = textColorFor(bg)
  if dim then bg, fg = colors.gray, colors.lightGray end

  for row = 0, h - 1 do
    mon.setCursorPos(x, y + row)
    mon.setBackgroundColor(bg)
    mon.write(string.rep(" ", w))
  end
  local label = cardLabel(card)
  if #label > w then label = label:sub(1, w) end
  local labelRow = math.floor((h - 1) / 2)
  local labelX = x + math.max(0, math.floor((w - #label) / 2))
  mon.setCursorPos(labelX, y + labelRow)
  mon.setTextColor(fg)
  mon.write(label)
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
-- Rendu complet d'un ecran pour le joueur `playerIndex`
-- ------------------------------------------------------------
-- retourne une table de "zones cliquables" : { {x1,y1,x2,y2, action=...}, ... }
local function renderPlayerScreen(G, playerIndex)
  local mon = monitors[playerIndex]
  local w, h = mon.getSize()
  mon.setBackgroundColor(colors.black)
  mon.clear()
  local clickZones = {}

  -- ligne 1 : etat de la partie
  mon.setCursorPos(1, 1)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(colors.white)
  if G.gameOver then
    mon.write("Partie terminee !")
  elseif G.currentPlayer == playerIndex then
    if G.pendingColorChoice then
      mon.write("Choisis une couleur")
    else
      mon.write("A toi de jouer !")
    end
  else
    mon.write("Tour du joueur " .. G.currentPlayer .. "...")
  end

  -- carte du dessus de la defausse + couleur en cours
  local top = topCard(G)
  drawCard(mon, 1, 3, top, false)
  mon.setCursorPos(1 + CARD_W + 1, 3)
  mon.setBackgroundColor(colors.black)
  mon.setTextColor(CARD_COLOR_MAP[G.currentColor] or colors.white)
  mon.write("Couleur: " .. G.currentColor)
  mon.setTextColor(colors.white)
  mon.setCursorPos(1 + CARD_W + 1, 4)
  mon.write(#G.drawPile .. " cartes a piocher")

  if G.gameOver then
    mon.setCursorPos(1, 6)
    if G.winner == playerIndex then
      mon.setTextColor(colors.lime)
      mon.write("Tu as gagne !")
    else
      mon.setTextColor(colors.red)
      mon.write("Joueur " .. G.winner .. " a gagne.")
    end
    mon.setTextColor(colors.white)
    drawButton(mon, 1, 8, 16, "Nouvelle partie", colors.lightGray, colors.black)
    clickZones[#clickZones + 1] = { x1 = 1, y1 = 8, x2 = 16, y2 = 8, action = "restart" }
    return clickZones
  end

  -- popup choix de couleur (prioritaire sur l'affichage de la main)
  if G.pendingColorChoice and G.currentPlayer == playerIndex then
    local colorNames = { "red", "yellow", "green", "blue" }
    local by = 6
    for i, cname in ipairs(colorNames) do
      local bx = 1 + (i - 1) * 6
      drawButton(mon, bx, by, 5, cname:sub(1, 4), CARD_COLOR_MAP[cname], textColorFor(CARD_COLOR_MAP[cname]))
      clickZones[#clickZones + 1] = { x1 = bx, y1 = by, x2 = bx + 4, y2 = by, action = "choose_color", color = cname }
    end
    return clickZones
  end

  -- bouton piocher (actif seulement si c'est le tour du joueur et qu'il
  -- n'a aucun coup jouable)
  local myTurn = (G.currentPlayer == playerIndex) and not G.pendingColorChoice
  local mustDraw = myTurn and not hasLegalMove(G, playerIndex)
  local drawY = 6
  drawButton(mon, 1, drawY, 10, "PIOCHER", mustDraw and colors.orange or colors.gray,
    mustDraw and colors.black or colors.lightGray)
  if mustDraw then
    clickZones[#clickZones + 1] = { x1 = 1, y1 = drawY, x2 = 10, y2 = drawY, action = "draw" }
  end

  -- main du joueur : grille de cartes avec retour a la ligne.
  -- Les cartes JOUABLES sont toujours affichees en premier : si la
  -- main est trop grande pour l'ecran, ce sont les cartes NON
  -- jouables qui sortent du cadre en priorite (jamais une carte
  -- qu'on pourrait vouloir jouer -- ca eviterait un blocage total).
  local hand = G.hands[playerIndex]
  local startY = drawY + 2
  mon.setCursorPos(1, startY - 1)
  mon.setTextColor(colors.white)
  mon.write("Ta main (" .. #hand .. ") :")

  local order = {}
  for i = 1, #hand do order[#order + 1] = i end
  if myTurn and not mustDraw then
    table.sort(order, function(ia, ib)
      local pa = isPlayable(hand[ia], G, hand, ia)
      local pb = isPlayable(hand[ib], G, hand, ib)
      if pa ~= pb then return pa end -- jouables d'abord
      return ia < ib
    end)
  end

  local availRows = math.max(1, math.floor((h - startY + 1) / (CARD_H + 1)))
  local colsNormal = math.max(1, math.floor(w / (CARD_W + 1)))
  local cardW, cardH, gap = CARD_W, CARD_H, 1
  if #hand > colsNormal * availRows then
    -- main trop grande pour la taille normale : bascule en compact
    cardW, cardH, gap = 3, 2, 0
  end
  local slotW, slotH = cardW + 1, cardH + gap
  local cols = math.max(1, math.floor(w / slotW))
  local rows = math.max(1, math.floor((h - startY + 1) / slotH))

  for pos, i in ipairs(order) do
    local card = hand[i]
    local col = (pos - 1) % cols
    local row = math.floor((pos - 1) / cols)
    local x = 1 + col * slotW
    local y = startY + row * slotH
    if row < rows and y + cardH - 1 <= h then
      local playable = myTurn and not mustDraw and isPlayable(card, G, hand, i)
      local dim = myTurn and not playable
      drawCard(mon, x, y, card, dim, cardW, cardH)
      if playable then
        clickZones[#clickZones + 1] = {
          x1 = x, y1 = y, x2 = x + cardW - 1, y2 = y + cardH - 1,
          action = "play", cardIdx = i,
        }
      end
    end
  end

  if #hand == 1 then
    mon.setCursorPos(1, h)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.yellow)
    mon.write("UNO !")
    mon.setTextColor(colors.white)
  end

  return clickZones
end

local lastClickZones = { {}, {} }

local function redrawAll(G)
  lastClickZones[1] = renderPlayerScreen(G, 1)
  lastClickZones[2] = renderPlayerScreen(G, 2)
end

local function zoneAt(zones, x, y)
  for _, z in ipairs(zones) do
    if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z end
  end
  return nil
end

local function handleZoneAction(G, playerIndex, zone)
  if zone.action == "restart" then
    return newGame()
  elseif zone.action == "play" then
    applyPlay(G, playerIndex, zone.cardIdx, nil)
  elseif zone.action == "draw" then
    applyDraw(G, playerIndex)
  elseif zone.action == "choose_color" then
    resolvePendingColorChoice(G, playerIndex, zone.color)
  end
  return G
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

local G = newGame()
redrawAll(G)
print("Uno lance sur " .. MONITOR_1_NAME .. " / " .. MONITOR_2_NAME .. ". Ctrl+T pour arreter.")

if _G.__UNO_AUTOPILOT then
  -- Mode de test : joue des parties completes via le VRAI pipeline
  -- (rendu -> zones cliquables -> action), sans jamais passer par
  -- os.pullEvent, pour valider aussi la couche UI/tactile.
  local gamesPlayed, totalTurns = 0, 0
  while gamesPlayed < _G.__UNO_AUTOPILOT_GAMES do
    local activePlayer = G.currentPlayer
    local zones = lastClickZones[activePlayer]
    if #zones == 0 then
      error("Aucune zone cliquable pour le joueur actif -- deadlock UI")
    end
    local chosen
    if G.gameOver then
      for _, z in ipairs(zones) do
        if z.action == "restart" then chosen = z break end
      end
    else
      local candidates = {}
      for _, z in ipairs(zones) do
        if z.action ~= "restart" then candidates[#candidates + 1] = z end
      end
      if #candidates == 0 then
        error("Aucune action disponible pour le joueur actif -- deadlock UI")
      end
      chosen = candidates[math.random(#candidates)]
    end
    G = handleZoneAction(G, activePlayer, chosen)
    redrawAll(G)
    totalTurns = totalTurns + 1
    if chosen.action == "restart" then
      gamesPlayed = gamesPlayed + 1
    end
    if totalTurns > _G.__UNO_AUTOPILOT_GAMES * 4000 then
      error("Autopilot: trop de tours sans terminer assez de parties (deadlock probable)")
    end
  end
  print(string.format("AUTOPILOT OK: %d parties, %d actions UI totales", gamesPlayed, totalTurns))
  return
end

while true do
  local event, side, x, y = os.pullEvent("monitor_touch")
  local playerIndex = (side == MONITOR_1_NAME) and 1 or (side == MONITOR_2_NAME) and 2 or nil
  if playerIndex then
    local zone = zoneAt(lastClickZones[playerIndex], x, y)
    if zone then
      G = handleZoneAction(G, playerIndex, zone)
      redrawAll(G)
    end
  end
end