-- portal_config.lua
-- Cree/edite le fichier de config "portal.cfg" au MEME endroit que ce programme.
-- Format (3 lignes) :
--   1) mod
--   2) niveau actuel
--   3) niveau max

local function getDir()
    return fs.getDir(shell.getRunningProgram())
end

local cfgPath = fs.combine(getDir(), "portal.cfg")

print("=== Config Portal Display ===")

write("Mod (ex: Mekanism): ")
local mod = read()

write("Niveau actuel (ex: 3): ")
local current = tonumber(read())

write("Niveau max (ex: 20): ")
local max = tonumber(read())

if mod == "" or not current or not max then
    print("Erreur : mod vide ou niveaux non numeriques.")
    return
end

local file = fs.open(cfgPath, "w")
file.writeLine(mod)
file.writeLine(tostring(current))
file.writeLine(tostring(max))
file.close()

print("OK -> " .. cfgPath)