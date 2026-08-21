-- install.lua
-- Installe vcs et vcsu dans /scripts, cree un dossier /home pour tes
-- propres scripts, et ajoute /scripts au PATH de facon persistante.
--
-- Usage :
--   wget https://raw.githubusercontent.com/<toi>/<repo>/main/install.lua install
--   install <owner/repo> [branch]

local SCRIPTS_DIR = "/scripts"
local HOME_DIR = "/home"
local STARTUP_FILE = "startup.lua"
local PATH_LINE = 'shell.setPath(shell.path() .. ":' .. SCRIPTS_DIR .. '")'

local FILES = { "vcs.lua", "vcsu.lua" }

local function download(url, dest)
    local response, err = http.get(url)
    if not response then
        return false, "Echec : " .. tostring(err)
    end
    local content = response.readAll()
    response.close()
    if not content or content == "" then
        return false, "Reponse vide."
    end
    if fs.exists(dest) then
        fs.delete(dest)
    end
    local f = fs.open(dest, "w")
    f.write(content)
    f.close()
    return true
end

local function ensureDir(path)
    if fs.exists(path) then
        if not fs.isDir(path) then
            print("Attention : " .. path .. " existe mais n'est pas un dossier.")
            return false
        end
        print(path .. " existe deja.")
        return true
    end
    fs.makeDir(path)
    print("Dossier cree : " .. path)
    return true
end

local function ensurePathPersisted()
    local existing = ""
    if fs.exists(STARTUP_FILE) then
        local f = fs.open(STARTUP_FILE, "r")
        existing = f.readAll()
        f.close()
    end

    if existing:find(PATH_LINE, 1, true) then
        print("startup.lua deja a jour (PATH).")
        return
    end

    local f = fs.open(STARTUP_FILE, "a")
    f.write("\n" .. PATH_LINE .. "\n")
    f.close()
    print("Ligne ajoutee a startup.lua :")
    print("  " .. PATH_LINE)
end

-- ==========================================================
-- Entry point
-- ==========================================================

local args = { ... }
local repo = args[1]
local branch = args[2] or "main"

if not repo then
    print("Usage: install <owner/repo> [branch]")
    return
end

if not repo:match("^[%w%-%_%.]+/[%w%-%_%.]+$") then
    print("Format invalide. Attendu : owner/repo (ex: Toastcie/mon-repo)")
    return
end

ensureDir(SCRIPTS_DIR)
ensureDir(HOME_DIR)

local okCount, failCount = 0, 0

for _, filename in ipairs(FILES) do
    local url = "https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/" .. filename
    local dest = fs.combine(SCRIPTS_DIR, (filename:gsub("%.lua$", "")))

    print("GET " .. url)
    local ok, err = download(url, dest)
    if ok then
        print("  OK -> " .. dest)
        okCount = okCount + 1
    else
        print("  " .. err)
        failCount = failCount + 1
    end
end

ensurePathPersisted()

-- applique le PATH tout de suite pour la session en cours,
-- pas besoin d'attendre un reboot
shell.setPath(shell.path() .. ":" .. SCRIPTS_DIR)

print(("Termine : %d ok, %d echec(s)"):format(okCount, failCount))
if okCount > 0 then
    print("Prochaine etape : vcs config " .. repo .. " " .. branch)
    print("Tes scripts perso : " .. HOME_DIR)
end