--[[
  subpixel.lua
  ---------------------------------------------------------------
  luaforcc :: rendu "sub-pixel" pour CC:Tweaked, en exploitant les
  32 glyphes 0x80-0x9F qui decoupent chaque case de moniteur en une
  grille de 2x3 "pixels" :

      1 2
      3 4
      5 6   <- ce dernier n'a pas de bit dedie, il est TOUJOURS
              affiche dans la couleur de fond de la case

  Un moniteur WxH caracteres devient donc un canevas de (2W)x(3H)
  pixels. Chaque case ne peut afficher que 2 couleurs parmi les 16 ;
  ce module choisit lesquelles (en minimisant l'erreur percue, via
  l'espace de couleur Oklab plutot que RGB) et le bon glyphe.

  Usage :
    local subpixel = dofile("subpixel.lua")
    -- grid[row][col] = une couleur CC (colors.red, etc.), row 1..H, col 1..W
    -- W doit etre pair, H doit etre un multiple de 3 (arrondis au
    -- plus proche sinon -- le reste est simplement ignore)
    subpixel.draw(monitor, x, y, grid, W, H)
]]

local M = {}

-- ============================================================
-- Palette CC:Tweaked (valeurs RGB par defaut du jeu)
-- ============================================================

local PALETTE_HEX = {
  [colors.white]     = 0xF0F0F0,
  [colors.orange]    = 0xF2B233,
  [colors.magenta]   = 0xE57FD8,
  [colors.lightBlue] = 0x99B2F2,
  [colors.yellow]    = 0xDEDE6C,
  [colors.lime]      = 0x7FCC19,
  [colors.pink]      = 0xF2B2CC,
  [colors.gray]      = 0x4C4C4C,
  [colors.lightGray] = 0x999999,
  [colors.cyan]      = 0x4C99B2,
  [colors.purple]    = 0xB266E5,
  [colors.blue]      = 0x3366CC,
  [colors.brown]     = 0x7F664C,
  [colors.green]     = 0x57A64E,
  [colors.red]       = 0xCC4C4C,
  [colors.black]     = 0x191919,
}

-- ============================================================
-- Conversion sRGB -> Oklab (espace perceptuellement uniforme :
-- "plus proche" y correspond a ce que l'oeil percoit, contrairement
-- a une distance euclidienne RGB brute qui est trompeuse)
-- ============================================================

local function srgbToLinear(v)
  v = v / 255
  if v <= 0.04045 then return v / 12.92 end
  return ((v + 0.055) / 1.055) ^ 2.4
end

local function rgbToOklab(hex)
  local r = srgbToLinear(math.floor(hex / 65536) % 256)
  local g = srgbToLinear(math.floor(hex / 256) % 256)
  local b = srgbToLinear(hex % 256)

  local l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
  local m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
  local s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
  local l_, m_, s_ = l ^ (1 / 3), m ^ (1 / 3), s ^ (1 / 3)

  return {
    0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
  }
end

local COLOR_LIST = {}
local OKLAB = {}
for c, hex in pairs(PALETTE_HEX) do
  COLOR_LIST[#COLOR_LIST + 1] = c
  OKLAB[c] = rgbToOklab(hex)
end
table.sort(COLOR_LIST) -- ordre stable (utile pour les tests / le determinisme)

-- Matrice de distances (au carre -- inutile de faire la racine, ca
-- ne change pas l'ordre) precalculee une seule fois : en boucle de
-- rendu, ce n'est plus que des lookups.
local DIST = {}
for _, c1 in ipairs(COLOR_LIST) do
  DIST[c1] = {}
  for _, c2 in ipairs(COLOR_LIST) do
    local a, b = OKLAB[c1], OKLAB[c2]
    local dl, da, db = a[1] - b[1], a[2] - b[2], a[3] - b[3]
    DIST[c1][c2] = dl * dl + da * da + db * db
  end
end

-- Distance perceptuelle (Oklab) entre 2 couleurs CC. Expose pour
-- tests / usages externes.
function M.colorDistance(c1, c2)
  return DIST[c1][c2]
end

-- ============================================================
-- Choix des 2 couleurs d'une case (6 pixels -> 2 couleurs)
-- ============================================================

-- `pixels` = liste de 6 couleurs CC, dans l'ordre haut-gauche,
-- haut-droite, milieu-gauche, milieu-droite, bas-gauche, bas-droite.
-- Retourne c1 (couleur majoritaire) et c2 (la 2e couleur qui
-- minimise l'erreur totale de quantification).
local function pickTwoColors(pixels)
  local freq, order = {}, {}
  for _, p in ipairs(pixels) do
    if not freq[p] then
      freq[p] = 0
      order[#order + 1] = p
    end
    freq[p] = freq[p] + 1
  end

  if #order == 1 then
    return order[1], order[1]
  end

  local c1 = order[1]
  for _, c in ipairs(order) do
    if freq[c] > freq[c1] then c1 = c end
  end

  if #order == 2 then
    local c2 = (order[1] == c1) and order[2] or order[1]
    return c1, c2
  end

  local bestC2, bestErr = nil, math.huge
  for _, cand in ipairs(order) do
    if cand ~= c1 then
      local err = 0
      for _, p in ipairs(pixels) do
        err = err + math.min(DIST[c1][p], DIST[cand][p])
      end
      if err < bestErr then
        bestErr, bestC2 = err, cand
      end
    end
  end
  return c1, bestC2
end

-- ============================================================
-- Case -> (glyphe, fg, bg)
-- ============================================================

-- Le 6e pixel (bas-droite) n'a pas de bit dedie : il est toujours
-- rendu dans la couleur de FOND. Si sa couleur reelle est plus
-- proche de c1 que de c2, on inverse les roles (fg<->bg, masque
-- inverse sur les bits 1-5) pour que ce pixel force soit quand meme
-- correct -- seuls les 5 autres pixels "payent" l'inversion.
local function pixelsToCell(pixels)
  local c1, c2 = pickTwoColors(pixels)

  local closerToC1 = {}
  for i = 1, 5 do
    local p = pixels[i]
    closerToC1[i] = DIST[c1][p] <= DIST[c2][p]
  end

  local p6 = pixels[6]
  local p6PrefersC1 = DIST[c1][p6] <= DIST[c2][p6]

  local fg, bg, mask = c1, c2, 0
  if p6PrefersC1 then
    fg, bg = c2, c1
    for i = 1, 5 do
      if not closerToC1[i] then mask = mask + (2 ^ (i - 1)) end
    end
  else
    for i = 1, 5 do
      if closerToC1[i] then mask = mask + (2 ^ (i - 1)) end
    end
  end

  local char = string.char(128 + mask)
  return char, fg, bg
end

-- Expose les briques pures (utile pour les tests hors CC).
M._internal = {
  pickTwoColors = pickTwoColors,
  pixelsToCell = pixelsToCell,
  COLOR_LIST = COLOR_LIST,
}

-- ============================================================
-- Rendu d'une grille de pixels sur un moniteur/terminal
-- ============================================================

-- `grid[row][col]` = couleur CC, row 1..gridH, col 1..gridW.
-- gridW/gridH sont arrondis au multiple pair/de-3 inferieur (le
-- reste, s'il y en a, est simplement ignore plutot que de planter).
function M.draw(mon, x, y, grid, gridW, gridH)
  local charCols = math.floor(gridW / 2)
  local charRows = math.floor(gridH / 3)

  for cr = 1, charRows do
    local textParts, fgParts, bgParts = {}, {}, {}
    for cc = 1, charCols do
      local px0 = (cc - 1) * 2
      local py0 = (cr - 1) * 3
      local pixels = {
        grid[py0 + 1][px0 + 1], grid[py0 + 1][px0 + 2],
        grid[py0 + 2][px0 + 1], grid[py0 + 2][px0 + 2],
        grid[py0 + 3][px0 + 1], grid[py0 + 3][px0 + 2],
      }
      local char, fg, bg = pixelsToCell(pixels)
      textParts[#textParts + 1] = char
      fgParts[#fgParts + 1] = colors.toBlit(fg)
      bgParts[#bgParts + 1] = colors.toBlit(bg)
    end
    mon.setCursorPos(x, y + cr - 1)
    mon.blit(table.concat(textParts), table.concat(fgParts), table.concat(bgParts))
  end

  return charCols, charRows -- dimensions en caracteres reellement dessinees
end

-- Cree une grille (gridW x gridH) uniformement remplie d'une
-- couleur -- pratique comme point de depart avant d'y "peindre".
function M.newGrid(gridW, gridH, fillColor)
  local grid = {}
  for r = 1, gridH do
    grid[r] = {}
    for c = 1, gridW do
      grid[r][c] = fillColor
    end
  end
  return grid
end

return M