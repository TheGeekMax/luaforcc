-- wireworld.lua
-- Automate cellulaire Wireworld sur moniteur CC:Tweaked.
--
-- Regles (voisinage de Moore, 8 voisins) :
--   tete      -> queue
--   queue     -> conducteur
--   conducteur-> tete si exactement 1 ou 2 voisins sont des tetes
--   vide      -> vide
--
-- L'ecran est homeomorphe a un tore : les bords se rejoignent. On y trace
-- un unique circuit ferme en serpentin, parcouru par un seul electron.
--
-- Geometrie du circuit
-- --------------------
-- Un virage a 90 degres ne fonctionne PAS : la cellule d'angle devient
-- diagonalement adjacente a celle situee deux crans en arriere du chemin.
-- Cette cellule, redevenue conductrice, voit alors deux tetes et se
-- rallume : l'electron reflue et le circuit degenere en bruit.
--
-- Les virages se font donc en deux temps, par deux pas diagonaux separes
-- par une cellule verticale, avec 3 lignes d'ecart entre deux passes.
-- Le chemin obtenu est un cycle induit : chaque cellule ne touche que son
-- predecesseur et son successeur, ce qui garantit un electron unique.
--
-- Une gouttiere de colonnes vides empeche les extremites des lignes de se
-- rejoindre par le bord gauche/droit du tore.
--
-- Le circuit est retrace et l'electron replace toutes les 60 secondes.

-- ==========================================================
-- Reglages
-- ==========================================================

local WANT_W, WANT_H = 50, 50   -- taille de grille souhaitee
local CELL_W = 2                -- cellules horizontales par pixel
local TEXT_SCALE = 0.5
local TICK = 0.05               -- secondes entre deux generations
local RESET_EVERY = 60          -- secondes avant regeneration
local GAP = 3                   -- ecart vertical entre deux lignes de fil

local EMPTY, HEAD, TAIL, COND = 0, 1, 2, 3

local STATE_COLORS = {
    [EMPTY] = colors.black,
    [HEAD]  = colors.lightBlue,
    [TAIL]  = colors.red,
    [COND]  = colors.orange,
}

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

if W < 8 or H < 2 * GAP then
    error("Ecran trop petit pour tracer un circuit.", 0)
end

if W ~= WANT_W or H ~= WANT_H then
    print(("Ecran %dx%d : grille reduite a %dx%d (demande %dx%d)")
        :format(scrW, scrH, W, H, WANT_W, WANT_H))
end

local offX = math.floor((scrW - W * CELL_W) / 2)
local offY = math.floor((scrH - H) / 2)

-- ==========================================================
-- Construction du circuit
-- ==========================================================

-- Nombre de lignes de fil : pair, pour que l'alternance des virages
-- gauche/droite se referme correctement sur le tore.
local ROWS = math.floor(math.floor(H / GAP) / 2) * 2
local GH = ROWS * GAP           -- hauteur reellement occupee par le circuit

if ROWS < 2 then
    error("Ecran trop court pour au moins deux lignes de fil.", 0)
end

local xL, xR = 1, W - 2         -- colonnes reservees aux virages
local xa, xb = xL + 1, xR - 1   -- etendue des lignes horizontales

-- path[i] = { x = ..., y = ... }, cycle ferme
local path = {}

local function push(x, y)
    path[#path + 1] = { x = x, y = y % GH }
end

for r = 0, ROWS - 1 do
    local y = r * GAP
    if r % 2 == 0 then
        -- parcours vers la droite, puis virage a droite
        for x = xa, xb do push(x, y) end
        push(xR, y + 1)
        push(xR, y + 2)
    else
        -- parcours vers la gauche, puis virage a gauche
        for x = xb, xa, -1 do push(x, y) end
        push(xL, y + 1)
        push(xL, y + 2)
    end
end

local PATH_LEN = #path

-- ==========================================================
-- Grille
-- ==========================================================

-- Tableau plat : index = y * W + x + 1 (x, y a partir de 0)
local grid = {}
local next_ = {}

local function idx(x, y)
    return y * W + x + 1
end

-- Indices plats des cellules du circuit, dans l'ordre du parcours.
local wire = {}
for i = 1, PATH_LEN do
    wire[i] = idx(path[i].x, path[i].y)
end

-- Decalages des 8 voisins, precalcules par cellule du circuit : le
-- voisinage est fige puisque le circuit ne bouge pas.
local neighbours = {}

local function buildNeighbours()
    neighbours = {}
    for i = 1, PATH_LEN do
        local p = path[i]
        local list = {}
        for dy = -1, 1 do
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    local nx = (p.x + dx) % W
                    local ny = (p.y + dy) % GH
                    list[#list + 1] = idx(nx, ny)
                end
            end
        end
        neighbours[i] = list
    end
end

local function reset()
    for i = 1, W * H do
        grid[i] = EMPTY
        next_[i] = EMPTY
    end
    for i = 1, PATH_LEN do
        grid[wire[i]] = COND
    end
    -- un seul electron : une queue derriere une tete donne le sens de marche
    grid[wire[1]] = TAIL
    grid[wire[2]] = HEAD
end

local function step()
    -- seules les cellules du circuit peuvent changer d'etat
    for i = 1, PATH_LEN do
        local c = wire[i]
        local s = grid[c]

        if s == HEAD then
            next_[c] = TAIL
        elseif s == TAIL then
            next_[c] = COND
        else
            local n = 0
            local list = neighbours[i]
            for k = 1, 8 do
                if grid[list[k]] == HEAD then n = n + 1 end
            end
            next_[c] = (n == 1 or n == 2) and HEAD or COND
        end
    end

    for i = 1, PATH_LEN do
        local c = wire[i]
        grid[c] = next_[c]
    end
end

-- ==========================================================
-- Rendu
-- ==========================================================

local RUNS = {}
for s, col in pairs(STATE_COLORS) do
    RUNS[s] = colors.toBlit(col):rep(CELL_W)
end

local TEXT = (" "):rep(W * CELL_W)
local prev = {}

local function render(force)
    local buf = {}
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            buf[x + 1] = RUNS[grid[idx(x, y)]]
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

buildNeighbours()
fullReset()

print(("Circuit : %d cellules, %d lignes."):format(PATH_LEN, ROWS))
print(("Un tour complet prend %.0f s."):format(PATH_LEN * TICK))

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