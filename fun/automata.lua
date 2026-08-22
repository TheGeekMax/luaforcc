-- automata.lua
-- Les quatre automates cellulaires en simultane, un par quadrant.
--
--   haut gauche  : jeu de la vie de Conway
--   haut droite  : pierre - papier - ciseaux
--   bas gauche   : Wireworld (circuit ferme, un seul electron)
--   bas droite   : fourmi de Langton
--
-- Chaque quadrant est un tore independant de 25x25. Un "pixel" occupe
-- 2 cellules horizontales pour rester carre. Tout est reinitialise
-- toutes les 60 secondes.
--
-- Les automates n'avancent pas a la meme cadence : un compteur de ticks
-- donne a chacun sa periode propre (voir le champ "every").

-- ==========================================================
-- Reglages
-- ==========================================================

local Q = 25                    -- cote d'un quadrant
local CELL_W = 2                -- cellules horizontales par pixel
local TEXT_SCALE = 0.5
local TICK = 0.05               -- cadence de base
local RESET_EVERY = 60

local GRID_W, GRID_H = Q * 2, Q * 2

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

if scrW < GRID_W * CELL_W or scrH < GRID_H then
    error(("Ecran trop petit : il faut %d colonnes x %d lignes (actuel %dx%d)")
        :format(GRID_W * CELL_W, GRID_H, scrW, scrH), 0)
end

local offX = math.floor((scrW - GRID_W * CELL_W) / 2)
local offY = math.floor((scrH - GRID_H) / 2)

-- ==========================================================
-- Tampon de couleurs partage
-- ==========================================================

-- cbuf[y * GRID_W + x + 1] = un caractere de couleur blit.
-- Chaque automate y ecrit son quadrant, le rendu lit l'ensemble.
local cbuf = {}

local function put(qx, qy, x, y, ch)
    local gx = qx * Q + x
    local gy = qy * Q + y
    cbuf[gy * GRID_W + gx + 1] = ch
end

local B = {}                    -- raccourci : B.lime, B.red, ...
for _, name in ipairs({
    "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink",
    "gray", "lightGray", "cyan", "purple", "blue", "brown", "green",
    "red", "black",
}) do
    B[name] = colors.toBlit(colors[name])
end

-- ==========================================================
-- Automate 1 : jeu de la vie
-- ==========================================================

local life = { qx = 0, qy = 0, every = 3, density = 0.35 }

function life:init()
    self.grid, self.next = {}, {}
    for i = 1, Q * Q do
        self.grid[i] = (math.random() < self.density) and 1 or 0
    end
end

function life:step()
    local g, n = self.grid, self.next
    for y = 0, Q - 1 do
        for x = 0, Q - 1 do
            local c = 0
            for dy = -1, 1 do
                for dx = -1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        c = c + g[((y + dy) % Q) * Q + (x + dx) % Q + 1]
                    end
                end
            end
            local i = y * Q + x + 1
            if g[i] == 1 then
                n[i] = (c == 2 or c == 3) and 1 or 0
            else
                n[i] = (c == 3) and 1 or 0
            end
        end
    end
    self.grid, self.next = n, g
end

function life:draw()
    for y = 0, Q - 1 do
        for x = 0, Q - 1 do
            put(self.qx, self.qy, x, y,
                self.grid[y * Q + x + 1] == 1 and B.lime or B.black)
        end
    end
end

-- ==========================================================
-- Automate 2 : pierre - papier - ciseaux
-- ==========================================================

local rps = { qx = 1, qy = 0, every = 3, threshold = 3 }
local RPS_COL = { B.red, B.lime, B.lightBlue }

function rps:init()
    self.grid, self.next = {}, {}
    for i = 1, Q * Q do
        self.grid[i] = math.random(3)
    end
end

function rps:step()
    local g, n = self.grid, self.next
    for y = 0, Q - 1 do
        for x = 0, Q - 1 do
            local i = y * Q + x + 1
            local s = g[i]
            local pred = s % 3 + 1      -- l'etat qui bat s
            local c = 0
            for dy = -1, 1 do
                for dx = -1, 1 do
                    if dx ~= 0 or dy ~= 0 then
                        if g[((y + dy) % Q) * Q + (x + dx) % Q + 1] == pred then
                            c = c + 1
                        end
                    end
                end
            end
            n[i] = (c >= self.threshold) and pred or s
        end
    end
    self.grid, self.next = n, g
end

function rps:draw()
    for y = 0, Q - 1 do
        for x = 0, Q - 1 do
            put(self.qx, self.qy, x, y, RPS_COL[self.grid[y * Q + x + 1]])
        end
    end
end

-- ==========================================================
-- Automate 3 : Wireworld
-- ==========================================================

-- Le circuit est un cycle induit : chaque cellule ne touche que son
-- predecesseur et son successeur. Les virages se font en deux pas
-- diagonaux, sinon l'electron reflue et le circuit degenere en bruit.

local EMPTY, HEAD, TAIL, COND = 0, 1, 2, 3
local WW_COL = {
    [EMPTY] = B.black,
    [HEAD]  = B.lightBlue,
    [TAIL]  = B.red,
    [COND]  = B.orange,
}

local ww = { qx = 0, qy = 1, every = 1, gap = 3 }

function ww:build()
    local rows = math.floor(math.floor(Q / self.gap) / 2) * 2
    self.rows = rows
    self.gh = rows * self.gap   -- hauteur reellement occupee

    local xL, xR = 1, Q - 2     -- colonnes de virage
    local xa, xb = xL + 1, xR - 1

    self.path = {}
    local function push(x, y)
        self.path[#self.path + 1] = { x = x, y = y % self.gh }
    end

    for r = 0, rows - 1 do
        local y = r * self.gap
        if r % 2 == 0 then
            for x = xa, xb do push(x, y) end
            push(xR, y + 1)
            push(xR, y + 2)
        else
            for x = xb, xa, -1 do push(x, y) end
            push(xL, y + 1)
            push(xL, y + 2)
        end
    end

    self.len = #self.path

    -- indices plats et voisinages, figes puisque le circuit ne bouge pas
    self.wire, self.neigh = {}, {}
    for i = 1, self.len do
        local p = self.path[i]
        self.wire[i] = p.y * Q + p.x + 1
        local list = {}
        for dy = -1, 1 do
            for dx = -1, 1 do
                if dx ~= 0 or dy ~= 0 then
                    list[#list + 1] =
                        ((p.y + dy) % self.gh) * Q + (p.x + dx) % Q + 1
                end
            end
        end
        self.neigh[i] = list
    end
end

function ww:init()
    if not self.path then self:build() end
    self.grid, self.next = {}, {}
    for i = 1, Q * Q do
        self.grid[i] = EMPTY
        self.next[i] = EMPTY
    end
    for i = 1, self.len do
        self.grid[self.wire[i]] = COND
    end
    -- une queue derriere une tete : l'electron a un sens de marche
    self.grid[self.wire[1]] = TAIL
    self.grid[self.wire[2]] = HEAD
end

function ww:step()
    local g, n = self.grid, self.next
    for i = 1, self.len do
        local c = self.wire[i]
        local s = g[c]
        if s == HEAD then
            n[c] = TAIL
        elseif s == TAIL then
            n[c] = COND
        else
            local h, list = 0, self.neigh[i]
            for k = 1, 8 do
                if g[list[k]] == HEAD then h = h + 1 end
            end
            n[c] = (h == 1 or h == 2) and HEAD or COND
        end
    end
    for i = 1, self.len do
        local c = self.wire[i]
        g[c] = n[c]
    end
end

function ww:draw()
    for y = 0, Q - 1 do
        for x = 0, Q - 1 do
            put(self.qx, self.qy, x, y, WW_COL[self.grid[y * Q + x + 1]])
        end
    end
end

-- ==========================================================
-- Automate 4 : fourmi de Langton
-- ==========================================================

-- Un pas ne change qu'une case : il en faut beaucoup par rendu pour
-- que quelque chose se passe a l'echelle d'un quadrant.
local ant = { qx = 1, qy = 1, every = 1, perTick = 25 }

local ANT_DIRS = {
    { dx = 0, dy = -1 },        -- haut
    { dx = 1, dy = 0 },         -- droite
    { dx = 0, dy = 1 },         -- bas
    { dx = -1, dy = 0 },        -- gauche
}

function ant:init()
    self.grid = {}
    for i = 1, Q * Q do
        self.grid[i] = false    -- false = blanc, true = noir
    end
    self.x = math.floor(Q / 2)
    self.y = math.floor(Q / 2)
    self.dir = 1
end

function ant:step()
    for _ = 1, self.perTick do
        local i = self.y * Q + self.x + 1
        if self.grid[i] then
            self.dir = (self.dir - 2) % 4 + 1   -- a gauche
            self.grid[i] = false
        else
            self.dir = self.dir % 4 + 1         -- a droite
            self.grid[i] = true
        end
        local d = ANT_DIRS[self.dir]
        self.x = (self.x + d.dx) % Q
        self.y = (self.y + d.dy) % Q
    end
end

function ant:draw()
    for y = 0, Q - 1 do
        for x = 0, Q - 1 do
            put(self.qx, self.qy, x, y,
                self.grid[y * Q + x + 1] and B.black or B.white)
        end
    end
    put(self.qx, self.qy, self.x, self.y, B.red)
end

-- ==========================================================
-- Rendu
-- ==========================================================

local AUTOMATA = { life, rps, ww, ant }

local TEXT = (" "):rep(GRID_W * CELL_W)
local prev = {}

local function render(force)
    local buf = {}
    for y = 0, GRID_H - 1 do
        local rowBase = y * GRID_W
        for x = 0, GRID_W - 1 do
            buf[x + 1] = cbuf[rowBase + x + 1]:rep(CELL_W)
        end
        local line = table.concat(buf)

        if force or prev[y] ~= line then
            out.setCursorPos(offX + 1, offY + y + 1)
            out.blit(TEXT, line, line)
            prev[y] = line
        end
    end
end

local function drawAll()
    for _, a in ipairs(AUTOMATA) do
        a:draw()
    end
end

local function fullReset()
    for _, a in ipairs(AUTOMATA) do
        a:init()
    end
    drawAll()
    out.setBackgroundColor(colors.black)
    out.clear()
    prev = {}
    render(true)
end

-- ==========================================================
-- Boucle principale
-- ==========================================================

math.randomseed(os.epoch("utc") % 2147483647)
fullReset()

print(("4 automates en %dx%d. Wireworld : %d cellules de circuit.")
    :format(Q, Q, ww.len))

local ticks = 0
local tickTimer = os.startTimer(TICK)
local resetTimer = os.startTimer(RESET_EVERY)

while true do
    local event, id = os.pullEvent()

    if event == "timer" then
        if id == tickTimer then
            ticks = ticks + 1
            local moved = false

            for _, a in ipairs(AUTOMATA) do
                if ticks % a.every == 0 then
                    a:step()
                    a:draw()
                    moved = true
                end
            end

            if moved then render(false) end
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