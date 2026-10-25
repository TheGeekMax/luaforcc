-- autocraft_setup.lua -- assistant de configuration de l'autocraft AE2
-- Pose les questions une par une, puis ecrit /autocraft/config.cfg
-- (et cree /autocraft/items.cfg s'il n'existe pas).
-- Entree vide = garder la valeur proposee entre crochets.

local DIR = "/autocraft"
local CFG_PATH = DIR .. "/config.cfg"
local ITEMS_PATH = DIR .. "/items.cfg"

local DEFAULTS = {
  jour = 50, nuit = 90, batch_items = 64, batch_fluids = 64,
  timeout = 30, max_echecs = 3, intervalle = 5, echelle = 1,
}

---------------------------------------------------------------------------
-- Utilitaires
---------------------------------------------------------------------------
local function tc(c) if term.isColor() then term.setTextColor(c) end end

local function header(step, total, title)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  tc(colors.yellow); print("AUTOCRAFT AE2 - configuration")
  tc(colors.gray); print(string.rep("-", (term.getSize())))
  if step then tc(colors.lightGray); print("Etape " .. step .. "/" .. total .. " : " .. title) end
  print("")
end

local function readFile(p)
  local h = fs.open(p, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

local function writeAtomic(p, s)
  local tmp = p .. ".tmp"
  local h = fs.open(tmp, "w")
  h.write(s)
  h.close()
  if fs.exists(p) then fs.delete(p) end
  fs.move(tmp, p)
end

local function loadExisting()
  local s = readFile(CFG_PATH)
  if not s then return nil end
  local f = load("return " .. s, "@config.cfg", "t", {})
  if not f then return nil end
  local ok, t = pcall(f)
  if ok and type(t) == "table" then return t end
  return nil
end

-- Demande un nombre avec valeur par defaut et bornes
local function askNumber(question, help, def, lo, hi, integer)
  while true do
    tc(colors.white); print(question)
    if help then tc(colors.gray); print(help) end
    tc(colors.lightGray); write("[" .. tostring(def) .. "] > ")
    tc(colors.lime)
    local s = read()
    if s == "" then return def end
    local n = tonumber((s:gsub(",", ".")))
    if n and integer and n ~= math.floor(n) then n = nil end
    if n and (not lo or n >= lo) and (not hi or n <= hi) then return n end
    tc(colors.red)
    local range = ""
    if lo and hi then range = " entre " .. lo .. " et " .. hi
    elseif lo then range = " >= " .. lo end
    print("Valeur invalide, entre un nombre" .. (integer and " entier" or "") .. range .. ".")
    print("")
  end
end

-- Demande de choisir un peripherique parmi ceux detectes
local function askPeripheral(question, ptype, current, filter)
  local names = {}
  for _, n in ipairs(peripheral.getNames()) do
    if peripheral.hasType(n, ptype) and (not filter or filter(peripheral.wrap(n))) then
      names[#names + 1] = n
    end
  end
  table.sort(names)
  while true do
    tc(colors.white); print(question)
    tc(colors.gray); print("0. Detection automatique")
    for i, n in ipairs(names) do
      tc(n == current and colors.lime or colors.lightGray); print(i .. ". " .. n)
    end
    if #names == 0 then tc(colors.orange); print("(aucun " .. ptype .. " detecte pour l'instant)") end
    local def = 0
    for i, n in ipairs(names) do if n == current then def = i end end
    tc(colors.lightGray); write("[" .. def .. "] > ")
    tc(colors.lime)
    local s = read()
    local n = (s == "") and def or tonumber(s)
    if n == 0 then return nil end
    if n and names[n] then return names[n] end
    tc(colors.red); print("Choix invalide."); print("")
  end
end

local function askYesNo(question, def)
  while true do
    tc(colors.white); write(question .. (def and " [O/n] " or " [o/N] "))
    tc(colors.lime)
    local s = read():lower()
    if s == "" then return def end
    if s == "o" or s == "oui" or s == "y" then return true end
    if s == "n" or s == "non" then return false end
  end
end

local function fmtNum(n)
  if n == math.floor(n) then return string.format("%d", n) end
  return tostring(n)
end

local function buildConfig(c)
  local function per(key, name)
    if c[key] then return string.format("  %s = %q,", key, c[key]) end
    return string.format("  -- %s = %q,", key, name)
  end
  return table.concat({
    "{",
    "  -- Pourcentage des CPUs de craft utilisables (les CPUs en PLAYER_ONLY sont exclus du calcul)",
    "  jour = " .. fmtNum(c.jour) .. ",",
    "  nuit = " .. fmtNum(c.nuit) .. ",",
    "",
    "  -- Taille de chaque requete : un batch a la fois, jusqu'a atteindre le min",
    "  batch_items  = " .. fmtNum(c.batch_items) .. ",   -- en items",
    "  batch_fluids = " .. fmtNum(c.batch_fluids) .. ",   -- en seaux (1 seau = 1000 mB)",
    "",
    "  -- Echec : la requete n'apparait sur aucun CPU apres ce delai (secondes)",
    "  timeout = " .. fmtNum(c.timeout) .. ",",
    "  max_echecs = " .. fmtNum(c.max_echecs) .. ",",
    "",
    "  -- Secondes entre deux scans du reseau",
    "  intervalle = " .. fmtNum(c.intervalle) .. ",",
    "",
    "  -- Echelle du texte du moniteur (0.5 a 5)",
    "  echelle = " .. fmtNum(c.echelle) .. ",",
    "",
    "  -- Noms de peripheriques, laisser commente pour la detection automatique",
    per("bridge", "meBridge_0"),
    per("moniteur", "monitor_0"),
    "}",
  }, "\n") .. "\n"
end

---------------------------------------------------------------------------
-- Assistant
---------------------------------------------------------------------------
local old = loadExisting()
local cur = {}
for k, v in pairs(DEFAULTS) do
  cur[k] = (old and tonumber(old[k])) or v
end
cur.bridge = old and type(old.bridge) == "string" and old.bridge or nil
cur.moniteur = old and type(old.moniteur) == "string" and old.moniteur or nil

header()
if old then
  tc(colors.lightGray)
  print("Une config existe deja : ses valeurs sont proposees par defaut.")
else
  tc(colors.lightGray)
  print("Aucune config trouvee : on part des valeurs par defaut.")
end
print("Appuie sur Entree pour garder la valeur entre crochets.")
print("")
tc(colors.gray); write("Entree pour commencer..."); read()

local T = 6
local c = {}

header(1, T, "Charge CPU")
c.jour = askNumber("% des CPUs utilisables en mode JOUR ?", "Tu es connecte : on laisse de la place.", cur.jour, 0, 100)
print("")
c.nuit = askNumber("% des CPUs utilisables en mode NUIT ?", "Tu es absent : on peut tout prendre.", cur.nuit, 0, 100)

header(2, T, "Taille des requetes")
c.batch_items = askNumber("Batch pour les items ?", "Chaque requete = 1 batch, repete jusqu'au min.", cur.batch_items, 1, nil, true)
print("")
c.batch_fluids = askNumber("Batch pour les fluides (en seaux) ?", "Ex: 64 -> requetes de 64 000 mB.", cur.batch_fluids, 1, nil, true)

header(3, T, "Echecs")
c.timeout = askNumber("Delai avant echec (secondes) ?",
  "Si la requete n'apparait sur aucun CPU apres ce delai.", cur.timeout, 5)
print("")
c.max_echecs = askNumber("Nombre d'echecs avant SKIP ?", nil, cur.max_echecs, 1, nil, true)

header(4, T, "Rythme et affichage")
c.intervalle = askNumber("Secondes entre deux scans du reseau ?", "Plus bas = plus reactif, plus de charge.", cur.intervalle, 1)
print("")
c.echelle = askNumber("Echelle du texte du moniteur ?", "1 sur un 5x4, 0.5 pour plus de place.", cur.echelle, 0.5, 5)

header(5, T, "ME Bridge")
c.bridge = askPeripheral("Quel ME Bridge utiliser ?", "meBridge", cur.bridge)

header(6, T, "Moniteur")
c.moniteur = askPeripheral("Quel moniteur utiliser ? (avance uniquement)", "monitor", cur.moniteur,
  function(m) return m and m.isColor and m.isColor() end)

-- Resume
header(nil, nil, nil)
tc(colors.white); print("Resume :")
tc(colors.lightGray)
print("  Jour / Nuit    : " .. fmtNum(c.jour) .. "% / " .. fmtNum(c.nuit) .. "%")
print("  Batch          : " .. fmtNum(c.batch_items) .. " items / " .. fmtNum(c.batch_fluids) .. " seaux")
print("  Echec          : " .. fmtNum(c.timeout) .. " s, skip apres " .. fmtNum(c.max_echecs))
print("  Scan / echelle : " .. fmtNum(c.intervalle) .. " s / " .. fmtNum(c.echelle))
print("  ME Bridge      : " .. (c.bridge or "auto"))
print("  Moniteur       : " .. (c.moniteur or "auto"))
print("")

if not askYesNo("Enregistrer ?", true) then
  tc(colors.orange); print("Annule, rien n'a ete ecrit.")
  return
end

if not fs.exists(DIR) then fs.makeDir(DIR) end
writeAtomic(CFG_PATH, buildConfig(c))
tc(colors.lime); print("Ecrit : " .. CFG_PATH)

if not fs.exists(ITEMS_PATH) then
  writeAtomic(ITEMS_PATH, "{\n}\n")
  tc(colors.lime); print("Cree  : " .. ITEMS_PATH .. " (vide)")
elseif askYesNo("Vider la liste des items suivis ?", false) then
  writeAtomic(ITEMS_PATH, "{\n}\n")
  tc(colors.orange); print("items.cfg vide.")
end

print("")
if fs.exists("/autocraft.lua") and askYesNo("Lancer autocraft maintenant ?", true) then
  shell.run("autocraft")
else
  tc(colors.lightGray); print("Lance 'autocraft' quand tu veux.")
end