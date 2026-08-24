--[[
  puzzle_game.lua
  ---------------------------------------------------------------
  luaforcc :: mini-jeu d'automatisation (V1 jouable)

  Regles :
    - Des ressources brutes (couleurs) sont posees sur la grille.
    - Un ASSEMBLEUR combine 2 couleurs brutes precises des lors
      qu'elles se trouvent chacune dans une case ADJACENTE a lui
      (routage/flux : on approche les ressources de la machine,
      on ne les pose pas dessus). Il produit alors une ressource
      "tier 2" a la place de l'une des deux entrees.
    - Un OBJECTIF veut une couleur precise deposee DIRECTEMENT
      dessus -> victoire.
    - Des MURS bloquent le passage et forcent a contourner.
    - Le joueur touche une ressource pour la selectionner, puis
      touche une case adjacente (haut/bas/gauche/droite) libre
      pour l'y deplacer.

  Genere un puzzle a partir d'une recette, "a l'envers" :
  on decide de la recette -> on place assembleur + objectif ->
  on place les sources brutes -> on ajoute des murs seulement
  la ou ils ne cassent pas un chemin minimal verifie par BFS.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local GRID_W, GRID_H = 5, 5
local PIX_PER_BLOCK  = 4
local TEXT_SCALE     = 0.5
local BORDER         = 1
local BLOCK_STRIDE   = PIX_PER_BLOCK + BORDER
local WALL_COUNT     = 3

math.randomseed(os.epoch and os.epoch("utc") or os.time())

-- ============================================================
-- PERIPHERIQUE
-- ============================================================

local monitor = peripheral.find("monitor")
if not monitor then
  error("Aucun moniteur avance trouve. Branche un monitor et relance.")
end

monitor.setTextScale(TEXT_SCALE)
local mw, mh = monitor.getSize()

local gridPixelW = GRID_W * BLOCK_STRIDE - BORDER
local gridPixelH = GRID_H * BLOCK_STRIDE - BORDER
local originX = math.max(1, math.floor((mw - gridPixelW) / 2) + 1)
local originY = math.max(1, math.floor((mh - gridPixelH) / 2) + 1)

-- ============================================================
-- RECETTES DISPONIBLES (3 brutes -> 1 tier2 tiree au hasard par puzzle)
-- ============================================================

local RECIPES = {
  { a = colors.red,  b = colors.lime, out = colors.yellow  },
  { a = colors.lime, b = colors.blue, out = colors.cyan    },
  { a = colors.red,  b = colors.blue, out = colors.magenta },
}

-- ============================================================
-- ICONES 4x4
-- ============================================================

local function iconResource(color)
  return {
    { 0, color, color, 0 },
    { color, color, color, color },
    { color, color, color, color },
    { 0, color, color, 0 },
  }
end

local function iconWall()
  return {
    { colors.gray, colors.gray, colors.gray, colors.gray },
    { colors.gray, colors.lightGray, colors.lightGray, colors.gray },
    { colors.gray, colors.lightGray, colors.lightGray, colors.gray },
    { colors.gray, colors.gray, colors.gray, colors.gray },
  }
end

local function iconAssembler(colorA, colorB)
  return {
    { colorA, colors.gray, colors.gray, colorB },
    { colors.gray, colors.gray, colors.gray, colors.gray },
    { colors.gray, colors.gray, colors.gray, colors.gray },
    { colorA, colors.gray, colors.gray, colorB },
  }
end

local function iconGoal(color)
  return {
    { color, color, color, color },
    { color, 0, 0, color },
    { color, 0, 0, color },
    { color, color, color, color },
  }
end

-- ============================================================
-- ETAT DU PUZZLE
-- ============================================================

-- structure[by][bx] = nil | "wall" | { kind="assembler", a=colorA, b=colorB, out=colorOut } | { kind="goal", color=colorOut }
-- resource[by][bx]  = nil | color (ressource mobile posee au sol)

local structure, resource
local goalPos, targetColor

local function emptyBoard()
  structure, resource = {}, {}
  for by = 1, GRID_H do
    structure[by], resource[by] = {}, {}
  end
end

local function inBounds(bx, by)
  return bx >= 1 and bx <= GRID_W and by >= 1 and by <= GRID_H
end

local function neighbors(bx, by)
  return {
    { bx, by - 1 }, { bx, by + 1 }, { bx - 1, by }, { bx + 1, by },
  }
end

-- BFS : cases atteignables depuis (sx,sy) en traversant uniquement du "vide"
-- (pas de mur, pas d'assembleur, pas d'objectif) -- l'objectif/l'assembleur
-- ne sont atteignables qu'en tant que DESTINATION FINALE, pas en transit.
local function reachableEmpty(sx, sy, allowFinal)
  local seen = { [sy .. ":" .. sx] = true }
  local queue = { { sx, sy } }
  local result = {}
  local qi = 1
  while qi <= #queue do
    local cx, cy = queue[qi][1], queue[qi][2]
    qi = qi + 1
    result[cy .. ":" .. cx] = true
    for _, n in ipairs(neighbors(cx, cy)) do
      local nx, ny = n[1], n[2]
      if inBounds(nx, ny) and not seen[ny .. ":" .. nx] then
        seen[ny .. ":" .. nx] = true
        local s = structure[ny][nx]
        if s == nil then
          queue[#queue + 1] = { nx, ny }
        elseif allowFinal and allowFinal(nx, ny, s) then
          result[ny .. ":" .. nx] = true -- destination valable, mais pas de traversee au-dela
        end
      end
    end
  end
  return result
end

local function randomEmptyCell(exclude)
  exclude = exclude or {}
  local candidates = {}
  for by = 1, GRID_H do
    for bx = 1, GRID_W do
      local key = by .. ":" .. bx
      if structure[by][bx] == nil and resource[by][bx] == nil and not exclude[key] then
        candidates[#candidates + 1] = { bx, by }
      end
    end
  end
  if #candidates == 0 then return nil end
  return candidates[math.random(#candidates)]
end

-- ============================================================
-- GENERATION (a l'envers depuis une recette)
-- ============================================================

local function generateAttempt()
  emptyBoard()
  local recipe = RECIPES[math.random(#RECIPES)]
  targetColor = recipe.out

  local used = {}

  -- 1) Objectif : il lui faut au moins 1 case voisine libre, sinon
  -- il serait injoignable des le depart. Cette/ces case(s) voisine(s)
  -- sont reservees (comme les dropCells de l'assembleur plus bas)
  -- pour qu'un mur ne puisse jamais totalement l'enfermer.
  local gPos, goalNeighbors
  local attemptsG = 0
  repeat
    attemptsG = attemptsG + 1
    gPos = randomEmptyCell(used)
    goalNeighbors = {}
    if gPos then
      for _, n in ipairs(neighbors(gPos[1], gPos[2])) do
        local nx, ny = n[1], n[2]
        if inBounds(nx, ny) and structure[ny][nx] == nil then
          goalNeighbors[#goalNeighbors + 1] = { nx, ny }
        end
      end
    end
  until gPos and #goalNeighbors >= 1 or attemptsG > 100

  goalPos = { bx = gPos[1], by = gPos[2] }
  used[gPos[2] .. ":" .. gPos[1]] = true
  structure[gPos[2]][gPos[1]] = { kind = "goal", color = recipe.out }
  for _, n in ipairs(goalNeighbors) do
    used[n[2] .. ":" .. n[1]] = true
  end

  -- 2) Assembleur, pas colle a l'objectif, et avec au moins 2 cases
  -- voisines libres : il en faut au MOINS 2 pour pouvoir accueillir
  -- les 2 couleurs de la recette simultanement (sinon le puzzle est
  -- structurellement impossible a resoudre).
  local aPos, dropCells
  local attemptsA = 0
  repeat
    attemptsA = attemptsA + 1
    aPos = randomEmptyCell(used)
    dropCells = {}
    if aPos then
      for _, n in ipairs(neighbors(aPos[1], aPos[2])) do
        local nx, ny = n[1], n[2]
        if inBounds(nx, ny) and structure[ny][nx] == nil and not (nx == gPos[1] and ny == gPos[2]) then
          dropCells[#dropCells + 1] = { nx, ny }
        end
      end
    end
  until aPos and #dropCells >= 2
    and not (math.abs(aPos[1] - gPos[1]) <= 1 and math.abs(aPos[2] - gPos[2]) <= 1)
    or attemptsA > 100

  used[aPos[2] .. ":" .. aPos[1]] = true
  structure[aPos[2]][aPos[1]] = { kind = "assembler", a = recipe.a, b = recipe.b, out = recipe.out }

  -- les cases de livraison sont reservees : ni murs, ni sources n'y
  -- seront places directement, pour forcer un vrai deplacement et
  -- garder ces 2+ cases disponibles pour la fusion.
  for _, d in ipairs(dropCells) do
    used[d[2] .. ":" .. d[1]] = true
  end


  -- verifie qu'il existe un chemin vide entre une case et un ensemble de cases cibles
  local function pathExists(fromX, fromY, targets)
    local reach = reachableEmpty(fromX, fromY)
    for _, t in ipairs(targets) do
      if reach[t[2] .. ":" .. t[1]] then return true end
    end
    return false
  end

  -- 3) Sources brutes : une pour chaque couleur de la recette,
  -- placees de sorte qu'un chemin de cases vides existe jusqu'a
  -- une case de livraison de l'assembleur.
  local function placeSource(color)
    local pos
    local attempts = 0
    repeat
      pos = randomEmptyCell(used)
      attempts = attempts + 1
    until pos == nil or attempts > 40 or pathExists(pos[1], pos[2], dropCells)
    if pos then
      used[pos[2] .. ":" .. pos[1]] = true
      resource[pos[2]][pos[1]] = color
    end
    return pos
  end

  placeSource(recipe.a)
  placeSource(recipe.b)

  -- 4) Un peu de variete : une deuxieme source de la meme recette
  -- ailleurs (donne un chemin alternatif -> "plusieurs chemins valides")
  if math.random() < 0.5 then
    placeSource(recipe.a)
  else
    placeSource(recipe.b)
  end

  -- 5) Murs : ajoutes un par un, en verifiant qu'ils ne cassent pas
  -- un chemin restant entre chaque source et l'assembleur.
  local placedWalls = 0
  local tries = 0
  while placedWalls < WALL_COUNT and tries < 60 do
    tries = tries + 1
    local pos = randomEmptyCell(used)
    if pos then
      structure[pos[2]][pos[1]] = "wall"
      -- revalider que toutes les sources ont encore un chemin vers
      -- une case de livraison, ET que l'objectif est encore
      -- joignable depuis au moins une case de livraison.
      local ok = true
      for by = 1, GRID_H do
        for bx = 1, GRID_W do
          if resource[by][bx] ~= nil then
            if not pathExists(bx, by, dropCells) then ok = false end
          end
        end
      end
      if ok and not pathExists(goalPos.bx, goalPos.by, dropCells) then ok = false end
      if ok then
        used[pos[2] .. ":" .. pos[1]] = true
        placedWalls = placedWalls + 1
      else
        structure[pos[2]][pos[1]] = nil -- annule ce mur
      end
    end
  end
end

-- ============================================================
-- RENDU
-- ============================================================

local function drawPixel(px, py, color)
  if color == 0 or color == nil then color = colors.black end
  monitor.setCursorPos(px, py)
  monitor.setBackgroundColor(color)
  monitor.write(" ")
end

local selected -- { bx, by } de la ressource selectionnee

local function iconForCell(bx, by)
  local res = resource[by][bx]
  if res then return iconResource(res) end
  local s = structure[by][bx]
  if s == "wall" then return iconWall() end
  if s and s.kind == "assembler" then return iconAssembler(s.a, s.b) end
  if s and s.kind == "goal" then return iconGoal(s.color) end
  return nil
end

local function drawBlock(bx, by)
  local icon = iconForCell(bx, by)
  local baseX = originX + (bx - 1) * BLOCK_STRIDE
  local baseY = originY + (by - 1) * BLOCK_STRIDE
  local isSelected = selected and selected.bx == bx and selected.by == by

  for iy = 1, PIX_PER_BLOCK do
    for ix = 1, PIX_PER_BLOCK do
      local color = icon and icon[iy][ix] or 0
      if isSelected and color == 0 then color = colors.white end
      drawPixel(baseX + ix - 1, baseY + iy - 1, color)
    end
  end
end

local function drawAll()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()
  for by = 1, GRID_H do
    for bx = 1, GRID_W do
      drawBlock(bx, by)
    end
  end
  monitor.setCursorPos(1, 1)
end

local function screenToBlock(px, py)
  local relX, relY = px - originX, py - originY
  if relX < 0 or relY < 0 then return nil end
  local bx = math.floor(relX / BLOCK_STRIDE) + 1
  local by = math.floor(relY / BLOCK_STRIDE) + 1
  if bx < 1 or bx > GRID_W or by < 1 or by > GRID_H then return nil end
  local offX, offY = relX % BLOCK_STRIDE, relY % BLOCK_STRIDE
  if offX >= PIX_PER_BLOCK or offY >= PIX_PER_BLOCK then return nil end
  return bx, by
end

-- ============================================================
-- LOGIQUE DE JEU
-- ============================================================

-- Apres chaque deplacement : verifie chaque assembleur (fusion si
-- ses 2 couleurs sont presentes parmi ses voisins), puis verifie
-- si l'objectif a recu la bonne couleur.
local function resolveBoard()
  for by = 1, GRID_H do
    for bx = 1, GRID_W do
      local s = structure[by][bx]
      if s and s.kind == "assembler" then
        local foundA, foundB
        for _, n in ipairs(neighbors(bx, by)) do
          local nx, ny = n[1], n[2]
          if inBounds(nx, ny) then
            local r = resource[ny][nx]
            if r == s.a and not foundA then foundA = { nx, ny } end
            if r == s.b and not foundB and not (foundA and foundA[1] == nx and foundA[2] == ny) then
              foundB = { nx, ny }
            end
          end
        end
        if foundA and foundB then
          resource[foundA[2]][foundA[1]] = nil
          resource[foundB[2]][foundB[1]] = nil
          resource[foundA[2]][foundA[1]] = s.out -- le produit apparait sur une des 2 cases sources
        end
      end
    end
  end

  local s = structure[goalPos.by][goalPos.bx]
  if resource[goalPos.by][goalPos.bx] == s.color then
    return true
  end
  return false
end

local function tryMove(fromX, fromY, toX, toY)
  if math.abs(fromX - toX) + math.abs(fromY - toY) ~= 1 then return false end
  if resource[fromY][fromX] == nil then return false end
  if resource[toY][toX] ~= nil then return false end
  local destStruct = structure[toY][toX]
  if destStruct == "wall" then return false end
  if destStruct and destStruct.kind == "assembler" then return false end -- on ne pose pas dessus, on approche
  resource[toY][toX] = resource[fromY][fromX]
  resource[fromY][fromX] = nil
  return true
end

-- ============================================================
-- VERIFICATION DE SOLVABILITE (BFS reel sur l'espace d'etats)
-- ------------------------------------------------------------
-- La grille est petite (25 cases, 2-3 ressources) donc un BFS
-- complet sur les etats atteignables est instantane. On l'utilise
-- pour valider chaque plateau genere plutot que de se fier a des
-- heuristiques de chemin, qui peuvent rater des cas ou deux
-- ressources se genent mutuellement dans un couloir etroit.
-- ============================================================

local function serializeResources()
  local parts = {}
  for by = 1, GRID_H do
    for bx = 1, GRID_W do
      parts[#parts + 1] = tostring(resource[by][bx] or 0)
    end
  end
  return table.concat(parts, ",")
end

local function snapshotResources()
  local snap = {}
  for by = 1, GRID_H do
    snap[by] = {}
    for bx = 1, GRID_W do snap[by][bx] = resource[by][bx] end
  end
  return snap
end

local function restoreResources(snap)
  for by = 1, GRID_H do
    for bx = 1, GRID_W do resource[by][bx] = snap[by][bx] end
  end
end

local function boardIsSolvable(maxNodes)
  maxNodes = maxNodes or 4000
  local startSnap = snapshotResources()
  local visited = { [serializeResources()] = true }
  local queue = { startSnap }
  local qi, nodes = 1, 0
  local solved = false

  while qi <= #queue and not solved do
    nodes = nodes + 1
    if nodes > maxNodes then break end
    local snap = queue[qi]
    qi = qi + 1
    restoreResources(snap)

    for by = 1, GRID_H do
      for bx = 1, GRID_W do
        if resource[by][bx] ~= nil then
          for _, d in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
            local tx, ty = bx + d[1], by + d[2]
            if inBounds(tx, ty) then
              restoreResources(snap)
              if tryMove(bx, by, tx, ty) then
                if resolveBoard() then
                  solved = true
                  break
                end
                local key = serializeResources()
                if not visited[key] then
                  visited[key] = true
                  queue[#queue + 1] = snapshotResources()
                end
              end
            end
          end
        end
        if solved then break end
      end
      if solved then break end
    end
  end

  restoreResources(startSnap) -- ne jamais laisser une exploration polluer le vrai plateau
  return solved
end

local function generatePuzzle(maxAttempts)
  maxAttempts = maxAttempts or 25
  for attempt = 1, maxAttempts do
    generateAttempt()
    if boardIsSolvable() then return true end
  end
  return false -- tres improbable, mais on ne bloque jamais le joueur silencieusement
end

-- Hook de test interne (sans effet en jeu normal) : expose les
-- fonctions coeur pour permettre un solveur automatique externe.
_G.__puzzle_internal = {
  generatePuzzle = generatePuzzle,
  generateAttempt = generateAttempt,
  boardIsSolvable = boardIsSolvable,
  tryMove = tryMove,
  resolveBoard = resolveBoard,
  getState = function() return structure, resource, goalPos, targetColor, GRID_W, GRID_H end,
}

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

if _G.__PUZZLE_TEST_MODE then return end

generatePuzzle()
drawAll()
print("Puzzle genere. Deplace les ressources jusqu'a l'objectif (Ctrl+T pour arreter).")

local won = false
while not won do
  local event, side, x, y = os.pullEvent("monitor_touch")
  local bx, by = screenToBlock(x, y)
  if bx then
    if selected then
      if selected.bx == bx and selected.by == by then
        selected = nil -- deselection
      else
        local moved = tryMove(selected.bx, selected.by, bx, by)
        selected = nil
        if moved then
          won = resolveBoard()
        end
      end
    elseif resource[by][bx] ~= nil then
      selected = { bx = bx, by = by }
    end
  end
  drawAll()
  if won then
    print("Puzzle resolu !")
  end
end