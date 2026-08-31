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

-- ===== Police pixel-art 5x7 pour les gros chiffres =====
local FONT = {
    ["0"] = {"01110","10001","10011","10101","11001","10001","01110"},
    ["1"] = {"00100","01100","00100","00100","00100","00100","01110"},
    ["2"] = {"01110","10001","00001","00010","00100","01000","11111"},
    ["3"] = {"11110","00001","00001","01110","00001","00001","11110"},
    ["4"] = {"00010","00110","01010","10010","11111","00010","00010"},
    ["5"] = {"11111","10000","11110","00001","00001","10001","01110"},
    ["6"] = {"00110","01000","10000","11110","10001","10001","01110"},
    ["7"] = {"11111","00001","00010","00100","01000","01000","01000"},
    ["8"] = {"01110","10001","10001","01110","10001","10001","01110"},
    ["9"] = {"01110","10001","10001","01111","00001","00010","01100"},
}
local FONT_H = 7
local FONT_W = 5

-- Dessine un texte (chiffres uniquement) en gros pixel-art
local function drawBigNumber(x, y, text, scale, fg, bg)
    fg = fg or colours.black
    bg = bg or colours.white
    local cursorX = x
    for i = 1, #text do
        local ch = text:sub(i, i)
        local glyph = FONT[ch]
        if glyph then
            for row = 1, FONT_H do
                local line = glyph[row]
                for col = 1, FONT_W do
                    local bit = line:sub(col, col)
                    monitor.setBackgroundColour(bit == "1" and fg or bg)
                    local px = cursorX + (col - 1) * scale
                    local py = y + (row - 1) * scale
                    for sy = 0, scale - 1 do
                        monitor.setCursorPos(px, py + sy)
                        monitor.write(string.rep(" ", scale))
                    end
                end
            end
        end
        cursorX = cursorX + (FONT_W + 1) * scale
    end
    return cursorX - x - scale
end

local function textAt(x, y, text, fg, bg)
    monitor.setCursorPos(x, y)
    monitor.setTextColour(fg or colours.black)
    monitor.setBackgroundColour(bg or colours.white)
    monitor.write(text)
end

local function centerText(y, text, fg, bg)
    local w = select(1, monitor.getSize())
    text = text:sub(1, w)
    local x = math.max(1, math.floor((w - #text) / 2) + 1)
    textAt(x, y, text, fg, bg)
end

local function draw()
    local mod, current, max = loadConfig()
    local w, h = monitor.getSize()
    local margin = math.max(1, math.floor(w * 0.06))

    monitor.setBackgroundColour(colours.white)
    monitor.clear()

    -- En-tete : nom du mod
    centerText(2, mod)

    -- Ligne sous l'en-tete
    local dividerY = 3
    textAt(margin, dividerY, string.rep("-", w - margin * 2))

    -- Zone reservee en bas pour la barre de progression
    local barHeight = 2
    local barY = h - barHeight
    local footerTop = barY - 1 -- ligne de separation au-dessus de la barre

    -- Espace disponible pour le gros chiffre + la fraction cur/max
    local topOfNumbers = dividerY + 2
    local availH = footerTop - topOfNumbers - 2

    -- Plus grand scale possible pour le chiffre selon hauteur ET largeur dispo
    local currentStr = tostring(current)
    local scaleByHeight = math.max(1, math.floor(availH / FONT_H))
    local maxTextW = w - margin * 2
    local baseW = (#currentStr * (FONT_W + 1)) - 1
    local scaleByWidth = math.max(1, math.floor(maxTextW / baseW))
    local scale = math.max(1, math.min(scaleByHeight, scaleByWidth))

    local numberY = topOfNumbers
    drawBigNumber(margin, numberY, currentStr, scale, colours.black, colours.white)

    -- Fraction actuel / max, juste sous le gros chiffre
    local fracY = numberY + FONT_H * scale + 1
    textAt(margin, fracY, currentStr .. " / " .. tostring(max))

    -- Separation avant la barre
    textAt(margin, footerTop, string.rep("-", w - margin * 2))

    -- Barre de progression pleine largeur (noir = rempli, gris = restant)
    local ratio = math.min(1, math.max(0, current / max))
    local barW = w - margin * 2
    local filled = math.floor(ratio * barW + 0.5)
    for row = 0, barHeight - 1 do
        monitor.setCursorPos(margin, barY + row)
        for i = 1, barW do
            monitor.setBackgroundColour(i <= filled and colours.black or colours.lightGrey)
            monitor.write(" ")
        end
    end
end

local ok, err = pcall(draw)
if not ok then
    monitor.setBackgroundColour(colours.white)
    monitor.clear()
    centerText(2, "err cfg")
    print(err)
end

-- Rafraichit periodiquement au cas ou le fichier de config change
while true do
    os.sleep(2)
    pcall(draw)
end