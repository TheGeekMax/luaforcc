-- fleet.lua
-- Une flotte de vaisseaux "8==D" traverse l'ecran de gauche a droite,
-- deux par ligne, sur un fond d'etoiles fixes.
--
-- Chaque vaisseau a sa propre vitesse. Quand l'un rattrape celui qui le
-- precede, il ne le traverse pas : il echange sa place avec un vaisseau
-- d'une ligne voisine, a condition que les deux emplacements soient
-- libres. L'echange etant mutuel, chaque ligne conserve toujours son
-- compte de vaisseaux. Si aucun echange n'est possible, le vaisseau
-- change simplement d'allure et reessaiera a l'image suivante.
--
-- Tout s'adapte a la taille de l'ecran.

-- ==========================================================
-- Reglages
-- ==========================================================

local SHIP = "8==D"
local PER_LINE = 2              -- vaisseaux par ligne
local TICK = 0.08               -- secondes entre deux images
local STAR_DENSITY = 0.04       -- proportion de cases occupees par une etoile
local SPEED_MIN, SPEED_MAX = 0.25, 1.0   -- caracteres par image
local MARGIN = 1                -- espace minimal entre deux vaisseaux

local COL_SHIP = colors.white
local COL_STAR = colors.gray
local COL_BG = colors.black

-- ==========================================================
-- Sortie
-- ==========================================================

local out = peripheral.find("monitor")
if out then
    out.setTextScale(0.5)
else
    out = term.current()
end

local W, H = out.getSize()
local SHIP_LEN = #SHIP
local CLEAR = SHIP_LEN + MARGIN  -- ecart minimal entre deux positions

if W < CLEAR * PER_LINE then
    error("Ecran trop etroit pour la flotte.", 0)
end

local function randSpeed()
    return SPEED_MIN + math.random() * (SPEED_MAX - SPEED_MIN)
end

-- ==========================================================
-- Etoiles (fixes, dessinees sous les vaisseaux)
-- ==========================================================

-- stars[y] = table indexee par x : true si une etoile s'y trouve
local stars = {}

local function seedStars()
    stars = {}
    for y = 1, H do
        local row = {}
        for x = 1, W do
            if math.random() < STAR_DENSITY then
                row[x] = true
            end
        end
        stars[y] = row
    end
end

-- ==========================================================
-- Vaisseaux
-- ==========================================================

-- ships[y] = liste de { x = position flottante, speed = ... }
local ships = {}

local function seedShips()
    ships = {}
    local spacing = W / PER_LINE
    for y = 1, H do
        local line = {}
        for k = 0, PER_LINE - 1 do
            line[k + 1] = {
                -- decalage initial pour eviter un alignement en colonnes
                x = (k * spacing + math.random() * spacing) % W,
                speed = randSpeed(),
            }
        end
        ships[y] = line
    end
end

-- Distance de a vers b en avancant, sur un ecran qui reboucle.
local function gap(a, b)
    return (b - a) % W
end

-- La position x est-elle libre sur cette ligne, en ignorant "skip" ?
local function freeAt(line, x, skip)
    for _, o in ipairs(line) do
        if o ~= skip then
            if gap(x, o.x) < CLEAR or gap(o.x, x) < CLEAR then
                return false
            end
        end
    end
    return true
end

local function removeFrom(line, ship)
    for i, o in ipairs(line) do
        if o == ship then
            table.remove(line, i)
            return
        end
    end
end

-- Tente d'echanger "ship" (qui veut aller en nx) avec un vaisseau d'une
-- ligne voisine. L'echange n'a lieu que si chacun a la place chez l'autre.
local function trySwap(y, ship, nx)
    for _, ny in ipairs({ (y - 2) % H + 1, y % H + 1 }) do
        for _, other in ipairs(ships[ny]) do
            if freeAt(ships[ny], nx, other)
                and freeAt(ships[y], other.x, ship) then

                removeFrom(ships[y], ship)
                removeFrom(ships[ny], other)
                table.insert(ships[ny], ship)
                table.insert(ships[y], other)
                ship.x = nx
                return true
            end
        end
    end
    return false
end

local function advance()
    for y = 1, H do
        -- copie : la liste peut etre modifiee par un echange en cours de route
        local line = {}
        for i, s in ipairs(ships[y]) do line[i] = s end

        for _, s in ipairs(line) do
            local nx = (s.x + s.speed) % W

            if freeAt(ships[y], nx, s) then
                s.x = nx
            elseif not trySwap(y, s, nx) then
                -- coince : on change d'allure et on retentera plus tard
                s.speed = randSpeed()
            end
        end
    end
end

-- ==========================================================
-- Rendu
-- ==========================================================

local CH_SHIP = colors.toBlit(COL_SHIP)
local CH_STAR = colors.toBlit(COL_STAR)
local CH_BG = colors.toBlit(COL_BG)

local prev = {}

local function render(force)
    local text, fg, bg = {}, {}, {}

    for y = 1, H do
        local row = stars[y]

        -- fond : etoiles fixes
        for x = 1, W do
            if row[x] then
                text[x] = "."
                fg[x] = CH_STAR
            else
                text[x] = " "
                fg[x] = CH_BG
            end
            bg[x] = CH_BG
        end

        -- vaisseaux par-dessus
        for _, s in ipairs(ships[y]) do
            local base = math.floor(s.x)
            for i = 1, SHIP_LEN do
                local x = (base + i - 1) % W + 1
                text[x] = SHIP:sub(i, i)
                fg[x] = CH_SHIP
            end
        end

        local line = table.concat(text)
        if force or prev[y] ~= line then
            out.setCursorPos(1, y)
            out.blit(line, table.concat(fg), table.concat(bg))
            prev[y] = line
        end
    end
end

local function start()
    out.setBackgroundColor(COL_BG)
    out.clear()
    seedStars()
    seedShips()
    prev = {}
    render(true)
end

-- ==========================================================
-- Boucle principale
-- ==========================================================

math.randomseed(os.epoch("utc") % 2147483647)
start()

local timer = os.startTimer(TICK)

while true do
    local event, id = os.pullEvent()

    if event == "timer" and id == timer then
        advance()
        render(false)
        timer = os.startTimer(TICK)

    elseif event == "monitor_resize" or event == "term_resize" then
        W, H = out.getSize()
        start()

    elseif event == "key" or event == "monitor_touch" then
        break
    end
end

out.setBackgroundColor(colors.black)
out.clear()
out.setCursorPos(1, 1)