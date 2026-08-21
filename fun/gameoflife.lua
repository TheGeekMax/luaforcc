-- life.lua
-- Jeu de la vie de Conway sur moniteur CC:Tweaked.
--
-- Un "pixel" occupe 2 cellules horizontales pour rester carre
-- (une cellule fait 6x9 px, donc 2 cellules = 12x9, quasi carre).
--
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
local DENSITY = 0.35            -- proportion de cellules vivantes au depart

local COL_ALIVE = colors.lime
local COL_DEAD = colors.black

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

-- Tableau plat : index = (y - 1) * W + x, valeur 0 ou 1.
local grid = {}
local next_ = {}

local function randomize()
    for i = 1, W * H do
        grid[i] = (math.random() < DENSITY) and 1 or 0
    end
end

-- Compte les voisins vivants, avec rebouclage sur les bords.
local function neighbours(x, y)
    local n = 0
    for dy = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local nx = (x + dx - 1) % W + 1
                local ny = (y + dy - 1) % H + 1
                n = n + grid[(ny - 1) * W + nx]
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
            local n = neighbours(x, y)
            if grid[i] == 1 then
                -- survie avec 2 ou 3 voisins
                next_[i] = (n == 2 or n == 3) and 1 or 0
            else
                -- naissance avec exactement 3 voisins
                next_[i] = (n == 3) and 1 or 0
            end
        end
    end
    grid, next_ = next_, grid
end

-- ==========================================================
-- Rendu
-- ==========================================================

-- blit attend des codes couleur sur un caractere.
local CH_ALIVE = colors.toBlit(COL_ALIVE)
local CH_DEAD = colors.toBlit(COL_DEAD)

local TEXT = (" "):rep(W * CELL_W)          -- que des espaces : seul le fond compte
local A_RUN = CH_ALIVE:rep(CELL_W)
local D_RUN = CH_DEAD:rep(CELL_W)

-- lignes precedemment affichees, pour ne redessiner que ce qui change
local prev = {}

local function render(force)
    local buf = {}
    for y = 1, H do
        local rowBase = (y - 1) * W
        for x = 1, W do
            buf[x] = (grid[rowBase + x] == 1) and A_RUN or D_RUN
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
    out.setBackgroundColor(COL_DEAD)
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