-- portal_display.lua
-- Lit "portal.cfg" (meme dossier que ce programme) et affiche mod / niveau
-- actuel / niveau max sur un moniteur, style carte de chambre de test Portal.
-- Reste toujours en scale 1 (monitor.setTextScale(1)).

local function getDir()
    return fs.getDir(shell.getRunningProgram())
end

local cfgPath = fs.combine(getDir(), "portal.cfg")

local function loadConfig()
    if not fs.exists(cfgPath) then
        error("Config introuvable : " .. cfgPath .. " (lance portal_config.lua d'abord)")
    end
    local file = fs.open(cfgPath, "r")
    local mod = file.readLine()
    local current = tonumber(file.readLine())
    local max = tonumber(file.readLine())
    file.close()
    if not mod or not current or not max then
        error("Config invalide dans " .. cfgPath)
    end
    return mod, current, max
end

local monitor = peripheral.find("monitor")
if not monitor then
    error("Aucun moniteur trouve")
end

monitor.setTextScale(1) -- toujours scale 1
local w, h = monitor.getSize()

local function centerText(y, text, fg, bg)
    fg = fg or colours.black
    bg = bg or colours.white
    text = text:sub(1, w)
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    monitor.setCursorPos(x, y)
    monitor.setTextColour(fg)
    monitor.setBackgroundColour(bg)
    monitor.write(text)
end

local function fillLine(y, char, fg, bg)
    monitor.setCursorPos(1, y)
    monitor.setTextColour(fg or colours.black)
    monitor.setBackgroundColour(bg or colours.white)
    monitor.write(string.rep(char or "-", w))
end

local function draw()
    local mod, current, max = loadConfig()

    monitor.setBackgroundColour(colours.white)
    monitor.clear()

    -- 1) nom du mod (haut)
    centerText(1, mod)

    -- 2) separateur
    if h >= 2 then fillLine(2, "-") end

    -- 3) niveau actuel, bien visible au centre
    local midY = math.max(3, math.floor(h / 2))
    centerText(midY, tostring(current))

    -- 4) fraction actuel / max juste en dessous
    if h >= midY + 1 then
        centerText(midY + 1, tostring(current) .. "/" .. tostring(max))
    end

    -- 5) derniere ligne : barre de progression noire/grise (cote Aperture)
    if h >= midY + 2 then
        local ratio = math.min(1, math.max(0, current / max))
        local filled = math.floor(ratio * w + 0.5)
        monitor.setCursorPos(1, h)
        for i = 1, w do
            monitor.setBackgroundColour(i <= filled and colours.black or colours.lightGrey)
            monitor.write(" ")
        end
    end
end

local ok, err = pcall(draw)
if not ok then
    monitor.setBackgroundColour(colours.white)
    monitor.clear()
    centerText(1, "err cfg")
    print(err)
end

-- Rafraichit periodiquement au cas ou le fichier de config change
while true do
    os.sleep(2)
    pcall(draw)
end