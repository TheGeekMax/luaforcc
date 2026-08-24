--[[
  pixelgrid_proto.lua
  ---------------------------------------------------------------
  Prototype pour luaforcc : moteur de rendu "pixel art" sur moniteur
  avance + mapping tactile <-> case de grille.

  Objectif de ce prototype : valider UNIQUEMENT
    1) qu'on peut dessiner des icones 4x4 "pixels" lisibles par case
    2) que le touch mappe correctement sur la bonne case

  Pas de logique de puzzle ici, juste le moteur visuel + input.
  A poser tel quel sur un ordinateur relie a un moniteur avance.
]]

-- ============================================================
-- CONFIG
-- ============================================================

local GRID_W, GRID_H   = 5, 5   -- nombre de cases (blocs) de la grille
local PIX_PER_BLOCK    = 4      -- resolution "pixel art" par case (4x4)
local TEXT_SCALE       = 0.5    -- finesse du moniteur (plus petit = plus de "pixels")

-- Chaque "pixel" logique = 1 caractere du moniteur en text scale 0.5.
-- Une case de grille occupe donc PIX_PER_BLOCK x PIX_PER_BLOCK caracteres,
-- plus une bordure de separation optionnelle.

local BORDER = 1 -- espace (en pixels) entre deux cases, pour bien les distinguer au toucher

local BLOCK_STRIDE = PIX_PER_BLOCK + BORDER

-- ============================================================
-- PERIPHERIQUE
-- ============================================================

local monitor = peripheral.find("monitor")
if not monitor then
  error("Aucun moniteur avance trouve. Branche un monitor et relance.")
end

monitor.setTextScale(TEXT_SCALE)
monitor.setBackgroundColor(colors.black)
monitor.clear()

local mw, mh = monitor.getSize()

-- ============================================================
-- ICONES DE DEMO (4x4), une table de couleurs par case
-- (0 = transparent -> fond noir)
-- ============================================================

local ICON_PLUS = {
  {0, colors.lime, colors.lime, 0},
  {colors.lime, colors.lime, colors.lime, colors.lime},
  {colors.lime, colors.lime, colors.lime, colors.lime},
  {0, colors.lime, colors.lime, 0},
}

local ICON_ARROW_RIGHT = {
  {0, colors.yellow, 0, 0},
  {0, 0, colors.yellow, 0},
  {colors.yellow, colors.yellow, colors.yellow, colors.yellow},
  {0, 0, colors.yellow, 0},
}

local ICON_BOX = {
  {colors.cyan, colors.cyan, colors.cyan, colors.cyan},
  {colors.cyan, 0, 0, colors.cyan},
  {colors.cyan, 0, 0, colors.cyan},
  {colors.cyan, colors.cyan, colors.cyan, colors.cyan},
}

local ICON_EMPTY = {
  {0, 0, 0, 0},
  {0, 0, 0, 0},
  {0, 0, 0, 0},
  {0, 0, 0, 0},
}

-- Placement de demo sur la grille (bx, by) -> icone
local demoGrid = {}
for by = 1, GRID_H do
  demoGrid[by] = {}
  for bx = 1, GRID_W do
    demoGrid[by][bx] = ICON_EMPTY
  end
end
demoGrid[1][1] = ICON_PLUS
demoGrid[2][3] = ICON_ARROW_RIGHT
demoGrid[3][5] = ICON_BOX
demoGrid[5][2] = ICON_PLUS

-- Case actuellement selectionnee (surlignee) par le dernier touch
local selected = nil -- {bx=, by=}

-- ============================================================
-- CALCUL DE L'ORIGINE (pour centrer la grille sur l'ecran)
-- ============================================================

local gridPixelW = GRID_W * BLOCK_STRIDE - BORDER
local gridPixelH = GRID_H * BLOCK_STRIDE - BORDER

local originX = math.max(1, math.floor((mw - gridPixelW) / 2) + 1)
local originY = math.max(1, math.floor((mh - gridPixelH) / 2) + 1)

-- ============================================================
-- RENDU
-- ============================================================

-- Dessine un seul "pixel" logique (1 caractere colore)
local function drawPixel(px, py, color)
  if color == 0 then color = colors.black end
  monitor.setCursorPos(px, py)
  monitor.setBackgroundColor(color)
  monitor.write(" ")
end

-- Dessine une case (bx, by) a partir de son icone 4x4,
-- avec un contour de surbrillance si c'est la case selectionnee
local function drawBlock(bx, by)
  local icon = demoGrid[by][bx]
  local baseX = originX + (bx - 1) * BLOCK_STRIDE
  local baseY = originY + (by - 1) * BLOCK_STRIDE

  local isSelected = selected and selected.bx == bx and selected.by == by

  for iy = 1, PIX_PER_BLOCK do
    for ix = 1, PIX_PER_BLOCK do
      local color = icon[iy][ix]
      if isSelected and color == 0 then
        color = colors.gray -- fond legerement eclairci pour montrer la selection
      end
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

-- ============================================================
-- TOUCH -> CASE DE GRILLE
-- ============================================================

-- Convertit une coordonnee ecran (px, py) en (bx, by), ou nil si hors grille / dans une bordure
local function screenToBlock(px, py)
  local relX = px - originX
  local relY = py - originY
  if relX < 0 or relY < 0 then return nil end

  local bx = math.floor(relX / BLOCK_STRIDE) + 1
  local by = math.floor(relY / BLOCK_STRIDE) + 1
  if bx < 1 or bx > GRID_W or by < 1 or by > GRID_H then return nil end

  -- verifie qu'on n'est pas tombe sur la bordure entre deux cases
  local offX = relX % BLOCK_STRIDE
  local offY = relY % BLOCK_STRIDE
  if offX >= PIX_PER_BLOCK or offY >= PIX_PER_BLOCK then return nil end

  return bx, by
end

-- ============================================================
-- BOUCLE PRINCIPALE
-- ============================================================

drawAll()
print("Prototype pixelgrid pret. Touche une case du moniteur (Ctrl+T pour arreter).")

while true do
  local event, side, x, y = os.pullEvent("monitor_touch")
  local bx, by = screenToBlock(x, y)
  if bx then
    selected = { bx = bx, by = by }
    print(("Touch -> case (%d,%d)"):format(bx, by))
  else
    selected = nil
    print("Touch hors grille / bordure")
  end
  drawAll()
end