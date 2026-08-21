-- rps.lua
-- Automate cellulaire "pierre - papier - ciseaux" sur moniteur CC:Tweaked.
--
-- Chaque cellule est dans un des trois etats. A chaque generation, on
-- compte parmi ses 8 voisins ceux qui portent l'etat qui la BAT : si ce
-- compte atteint le seuil, la cellule est convertie a cet etat.
--
--   pierre  <- battue par  papier
--   papier  <- battu par   ciseaux
--   ciseaux <- battus par  pierre
--
-- Le cycle sans vainqueur possible fait apparaitre des fronts d'onde qui
-- s'enroulent en spirales.
--
-- Un "pixel" occupe 2 cellules horizontales pour rester carre.
-- La grille est generee au hasard et repartie de zero toutes les 60s.
-- La topologie est torique : les bords se rejoignent.

-- ==========================================================
-- Reglages
-- ==========================================================

local WANT_W, WANT_H = 50, 50   -- taille de grille souhaitee
local CELL_W = 2                -- cellules horizontales par pixel
local TEXT_SCALE = 0.5          -- plus petit = plus de place
local TICK = 0.15               -- secondes entre deux generations
local RESET_EVERY = 60          -- secondes avant regeneration
local THRESHOLD = 3             -- voisins predateurs requis pour etre converti

-- couleur de chaque etat (1 = pierre, 2 = papier, 3 = ciseaux)
local STATE_COLORS = {
    colors.red,
    colors.lime,
    colors.lightBlue,
}

local COL_BG = colors.black

-- ==========================================================
-- Sortie (moniteur si dispo, sinon terminal)
-- ==========================================================

local out = peripheral.find("monitor")
if out then
    out.setTextScale(TEXT_SCALE)
else
    out = term.current()
    print("Aucun moniteur trouve, rendu dans le terminal.")
end

local scrW, scrH = out.getSize()

-- ==========================================================
-- Dimensionnement
-- ==========================================================

-- On rogne la grille si l'ecran est trop petit pour la taille voulue.
local W = math.min(WANT_W, math.floor(scrW / CELL_W))
local H = math.min(WANT_H, scrH)

if W < 3 or H < 3 then
    error("Ecran trop petit pour afficher quoi que ce soit.", 0)
end

if W ~= WANT_W or H ~= WANT_H then
    print(("Ecran %dx%d : grille reduite a %dx%d (demande %dx%d)")
        :format(scrW, scrH, W, H, WANT_W, WANT_H))
    print(("Pour du %dx%d il faudrait %d colonnes x %d lignes.")
        :format(WANT_W, WANT_H, WANT_W * CELL_W, WANT_H))
end

-- centrage
local offX = math.floor((scrW - W * CELL_W) / 2)
local offY = math.floor((scrH - H) / 2)

-- ==========================================================
-- Grille
-- ==========================================================

-- Tableau plat : index = (y - 1) * W + x, valeur dans {1, 2, 3}.
local grid = {}
local next_ = {}

local function randomize()
    for i = 1, W * H do
        grid[i] = math.random(3)
    end
end

-- L'etat qui bat s est le suivant dans le cycle 1 -> 2 -> 3 -> 1.
local function predatorOf(s)
    return s % 3 + 1
end

-- Compte les voisins portant l'etat "target", avec rebouclage aux bords.
local function countNeighbours(x, y, target)
    local n = 0
    for dy = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local nx = (x + dx - 1) % W + 1
                local ny = (y + dy - 1) % H + 1
                if grid[(ny - 1) * W + nx] == target then
                    n = n + 1
                end
            end
        end
    end
    return n
end

local function step()
    for y = 1, H do
        local rowBase = (y - 1) * W
        for x = 1, W do
            local i = rowBase + x
            local s = grid[i]
            local pred = predatorOf(s)

            if countNeighbours(x, y, pred) >= THRESHOLD then
                next_[i] = pred
            else
                next_[i] = s
            end
        end
    end
    grid, next_ = next_, grid
end

-- ==========================================================
-- Rendu
-- ==========================================================

-- blit attend un code couleur par caractere : on precalcule le motif
-- de CELL_W caracteres correspondant a chaque etat.
local RUNS = {}
for s = 1, 3 do
    RUNS[s] = colors.toBlit(STATE_COLORS[s]):rep(CELL_W)
end

local TEXT = (" "):rep(W * CELL_W)   -- que des espaces : seul le fond compte

-- lignes precedemment affichees, pour ne redessiner que ce qui change
local prev = {}

local function render(force)
    local buf = {}
    for y = 1, H do
        local rowBase = (y - 1) * W
        for x = 1, W do
            buf[x] = RUNS[grid[rowBase + x]]
        end
        local line = table.concat(buf)

        if force or prev[y] ~= line then
            out.setCursorPos(offX + 1, offY + y)
            out.blit(TEXT, line, line)
            prev[y] = line
        end
    end
end

local function reset()
    randomize()
    out.setBackgroundColor(COL_BG)
    out.clear()
    prev = {}
    render(true)
end

-- ==========================================================
-- Boucle principale
-- ==========================================================

math.randomseed(os.epoch("utc") % 2147483647)
reset()

local tickTimer = os.startTimer(TICK)
local resetTimer = os.startTimer(RESET_EVERY)

while true do
    local event, id = os.pullEvent()

    if event == "timer" then
        if id == tickTimer then
            step()
            render(false)
            tickTimer = os.startTimer(TICK)

        elseif id == resetTimer then
            reset()
            resetTimer = os.startTimer(RESET_EVERY)
        end

    elseif event == "monitor_resize" or event == "term_resize" then
        -- on repart proprement : les dimensions ont change
        print("Redimensionnement detecte, relance le programme.")
        break

    elseif event == "key" or event == "monitor_touch" then
        break
    end
end

out.setBackgroundColor(colors.black)
out.clear()
out.setCursorPos(1, 1)