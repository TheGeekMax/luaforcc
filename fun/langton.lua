-- langton.lua
-- Fourmi de Langton sur moniteur CC:Tweaked.
--
-- Regles, sur une grille de cases noires ou blanches :
--   case blanche -> tourne a droite, noircit la case, avance d'un pas
--   case noire   -> tourne a gauche, blanchit la case, avance d'un pas
--
-- Deux regles triviales, mais le comportement ne l'est pas : environ
-- 10 000 pas de chaos apparent, puis la fourmi se met brusquement a
-- construire une "autoroute", motif periodique de 104 pas qui file en
-- diagonale indefiniment.
--
-- L'ecran etant un tore, la fourmi finit par revenir sur ses propres
-- traces : l'autoroute se brise et le chaos reprend.
--
-- Un "pixel" occupe 2 cellules horizontales pour rester carre.
-- La grille est remise a zero toutes les 60 secondes.

-- ==========================================================
-- Reglages
-- ==========================================================

local WANT_W, WANT_H = 50, 50   -- taille de grille souhaitee
local CELL_W = 2                -- cellules horizontales par pixel
local TEXT_SCALE = 0.5
local TICK = 0.05               -- secondes entre deux rendus
local STEPS_PER_TICK = 40       -- pas de fourmi par rendu
local RESET_EVERY = 60          -- secondes avant regeneration

local COL_WHITE = colors.white  -- case "blanche"
local COL_BLACK = colors.black  -- case "noire"
local COL_ANT = colors.red      -- position de la fourmi

-- ==========================================================
-- Sortie
-- ==========================================================

local out = peripheral.find("monitor")
if out then
    out.setTextScale(TEXT_SCALE)
else
    out = term.current()
    print("Aucun moniteur trouve, rendu dans le terminal.")
end

local scrW, scrH = out.getSize()

local W = math.min(WANT_W, math.floor(scrW / CELL_W))
local H = math.min(WANT_H, scrH)

if W < 3 or H < 3 then
    error("Ecran trop petit pour afficher quoi que ce soit.", 0)
end

if W ~= WANT_W or H ~= WANT_H then
    print(("Ecran %dx%d : grille reduite a %dx%d (demande %dx%d)")
        :format(scrW, scrH, W, H, WANT_W, WANT_H))
end

local offX = math.floor((scrW - W * CELL_W) / 2)
local offY = math.floor((scrH - H) / 2)

-- ==========================================================
-- Grille et fourmi
-- ==========================================================

-- Tableau plat : index = y * W + x + 1 (x, y a partir de 0)
-- false = blanc, true = noir
local grid = {}

local function idx(x, y)
    return y * W + x + 1
end

-- Directions, dans l'ordre horaire : haut, droite, bas, gauche.
-- Tourner a droite = +1, tourner a gauche = -1 (modulo 4).
local DIRS = {
    { dx = 0, dy = -1 },
    { dx = 1, dy = 0 },
    { dx = 0, dy = 1 },
    { dx = -1, dy = 0 },
}

local antX, antY, antDir
local steps

local function reset()
    for i = 1, W * H do
        grid[i] = false
    end
    antX = math.floor(W / 2)
    antY = math.floor(H / 2)
    antDir = 1
    steps = 0
end

local function stepAnt()
    local i = idx(antX, antY)

    if grid[i] then
        -- case noire : a gauche, puis on blanchit
        antDir = (antDir - 2) % 4 + 1
        grid[i] = false
    else
        -- case blanche : a droite, puis on noircit
        antDir = antDir % 4 + 1
        grid[i] = true
    end

    local d = DIRS[antDir]
    antX = (antX + d.dx) % W
    antY = (antY + d.dy) % H

    steps = steps + 1
end

-- ==========================================================
-- Rendu
-- ==========================================================

local RUN_WHITE = colors.toBlit(COL_WHITE):rep(CELL_W)
local RUN_BLACK = colors.toBlit(COL_BLACK):rep(CELL_W)
local RUN_ANT = colors.toBlit(COL_ANT):rep(CELL_W)

local TEXT = (" "):rep(W * CELL_W)
local prev = {}

local function render(force)
    local buf = {}
    for y = 0, H - 1 do
        local rowBase = y * W
        for x = 0, W - 1 do
            buf[x + 1] = grid[rowBase + x + 1] and RUN_BLACK or RUN_WHITE
        end
        if y == antY then
            buf[antX + 1] = RUN_ANT
        end
        local line = table.concat(buf)

        if force or prev[y] ~= line then
            out.setCursorPos(offX + 1, offY + y + 1)
            out.blit(TEXT, line, line)
            prev[y] = line
        end
    end
end

local function fullReset()
    reset()
    out.setBackgroundColor(colors.black)
    out.clear()
    prev = {}
    render(true)
end

-- ==========================================================
-- Boucle principale
-- ==========================================================

fullReset()

print(("%d pas par rendu, soit environ %d pas/s.")
    :format(STEPS_PER_TICK, math.floor(STEPS_PER_TICK / TICK)))

local tickTimer = os.startTimer(TICK)
local resetTimer = os.startTimer(RESET_EVERY)

while true do
    local event, id = os.pullEvent()

    if event == "timer" then
        if id == tickTimer then
            for _ = 1, STEPS_PER_TICK do
                stepAnt()
            end
            render(false)
            tickTimer = os.startTimer(TICK)

        elseif id == resetTimer then
            fullReset()
            resetTimer = os.startTimer(RESET_EVERY)
        end

    elseif event == "monitor_resize" or event == "term_resize" then
        print("Redimensionnement detecte, relance le programme.")
        break

    elseif event == "key" or event == "monitor_touch" then
        break
    end
end

out.setBackgroundColor(colors.black)
out.clear()
out.setCursorPos(1, 1)