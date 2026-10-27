-- ccimg.lua : affiche des images subpixel (format CCI1) sur CC:Tweaked
--
-- Config (une seule fois) :
--   set ccimg.server http://IP:8888
--   set ccimg.token  SECRET          (si le serveur a un --token)
--
-- Commandes :
--   ccimg list                          liste images / textes du serveur
--   ccimg get  <nom|url> [options]      convertit côté serveur et affiche
--   ccimg show <fichier.cci> [options]  affiche un fichier local (hors ligne)
--   ccimg pull <nom> [options]          récupère un texte partagé et l'affiche
--   ccimg put  <fichier.cci> <nom>      partage un fichier local sur le serveur
--   ccimg reset [-m cote]               remet la palette d'origine
-- Options :
--   -m <cote|auto>  moniteur (sinon le terminal)
--   -s <echelle>    textScale du moniteur (défaut 0.5 = résolution max)
--   -o <fichier>    sauvegarde le texte reçu
--   --cc            garde la palette CC par défaut (plusieurs images côte à côte)

local B32 = "0123456789abcdefghijklmnopqrstuv"
local GLYPH = {}
for i = 1, 32 do GLYPH[B32:sub(i, i)] = string.char(0x7F + i) end -- 0x80..0x9F

settings.define("ccimg.server", { description = "URL du serveur ccimg", default = "http://127.0.0.1:8888", type = "string" })
settings.define("ccimg.token", { description = "Token du serveur ccimg", default = "", type = "string" })

-- Arguments -----------------------------------------------------------------
local args, opts, pos = { ... }, {}, {}
local i = 1
while i <= #args do
  local a = args[i]
  if a == "-m" or a == "-s" or a == "-o" then
    opts[a:sub(2)] = args[i + 1]
    i = i + 2
  elseif a == "--cc" then
    opts.cc = true
    i = i + 1
  else
    pos[#pos + 1] = a
    i = i + 1
  end
end

local function usage()
  print("ccimg list | get <nom|url> | show <fichier> | pull <nom> | put <fichier> <nom> | reset")
  print("options : -m <cote|auto> -s <echelle> -o <fichier> --cc")
  error("", 0)
end

-- HTTP ------------------------------------------------------------------------
local function request(path, params, body)
  if not http then error("API http désactivée dans la config", 0) end
  local base = settings.get("ccimg.server"):gsub("/+$", "")
  params = params or {}
  local token = settings.get("ccimg.token")
  if token ~= "" then params.k = token end
  local q = {}
  for k, v in pairs(params) do q[#q + 1] = k .. "=" .. textutils.urlEncode(tostring(v)) end
  local url = base .. path .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")

  local h, err, fail
  if body then h, err, fail = http.post(url, body) else h, err, fail = http.get(url) end
  if not h then
    local msg = err or "requête échouée"
    if fail then msg = msg .. " : " .. (fail.readAll() or ""); fail.close() end
    error(msg, 0)
  end
  local data = h.readAll()
  h.close()
  return data
end

-- Fichiers --------------------------------------------------------------------
local function readFile(path)
  local f = fs.open(path, "r")
  if not f then error("fichier introuvable : " .. path, 0) end
  local data = f.readAll()
  f.close()
  return data
end

local function writeFile(path, data)
  local f = fs.open(path, "w")
  f.write(data)
  f.close()
end

-- Format CCI1 -------------------------------------------------------------------
local function parse(text)
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
  if lines[1] ~= "CCI1" then error("format inconnu (CCI1 attendu)", 0) end
  local w, h = (lines[2] or ""):match("^(%d+) (%d+)")
  w, h = tonumber(w), tonumber(h)
  if not w then error("taille illisible", 0) end

  local pal = {}
  for hex in (lines[3] or ""):gmatch("%x+") do pal[#pal + 1] = tonumber(hex, 16) end
  if #pal ~= 16 then error("palette invalide", 0) end

  local rows = {}
  for y = 1, h do
    local r = lines[3 + y]
    if not r or #r < 3 * w then error("ligne " .. y .. " manquante ou trop courte", 0) end
    rows[y] = {
      (r:sub(1, w):gsub(".", GLYPH)),
      r:sub(w + 1, 2 * w),
      r:sub(2 * w + 1, 3 * w),
    }
  end
  return { w = w, h = h, pal = pal, rows = rows }
end

-- Affichage ---------------------------------------------------------------------
local function resetPalette(t)
  for c = 0, 15 do t.setPaletteColour(2 ^ c, term.nativePaletteColour(2 ^ c)) end
end

local function draw(t, img, keepPalette)
  if not keepPalette then
    for c = 1, 16 do t.setPaletteColour(2 ^ (c - 1), img.pal[c]) end
  end
  -- fond = couleur de fond du coin haut-gauche de l'image
  t.setBackgroundColour(2 ^ tonumber(img.rows[1][3]:sub(1, 1), 16))
  t.clear()
  local tw, th = t.getSize()
  local ox = math.max(1, math.floor((tw - img.w) / 2) + 1)
  local oy = math.max(1, math.floor((th - img.h) / 2) + 1)
  for y = 1, img.h do
    t.setCursorPos(ox, oy + y - 1)
    t.blit(img.rows[y][1], img.rows[y][2], img.rows[y][3])
  end
end

local function target()
  local t, isMon = term.current(), false
  if opts.m then
    t = (opts.m == "auto") and peripheral.find("monitor") or peripheral.wrap(opts.m)
    if not t or not t.setTextScale then error("moniteur introuvable : " .. opts.m, 0) end
    t.setTextScale(tonumber(opts.s) or 0.5)
    isMon = true
  end
  if not t.isColour() then error("écran couleur (Advanced) requis", 0) end
  return t, isMon
end

local function display(text, t, isMon)
  local img = parse(text)
  if opts.o then writeFile(opts.o, text) end
  draw(t, img, opts.cc)
  if isMon then
    print(("Image %dx%d affichée sur le moniteur."):format(img.w, img.h))
    if opts.o then print("Sauvegardée dans " .. opts.o) end
  else
    os.pullEvent("key")
    resetPalette(t)
    t.setBackgroundColour(colours.black)
    t.setTextColour(colours.white)
    t.clear()
    t.setCursorPos(1, 1)
    if opts.o then print("Sauvegardée dans " .. opts.o) end
  end
end

-- Commandes ---------------------------------------------------------------------
local function main()
  local cmd = pos[1]
  if cmd == "list" then
    write(request("/list"))
  elseif cmd == "get" then
    local src = pos[2] or usage()
    local t, isMon = target()
    local w, h = t.getSize()
    local p = { w = w, h = h }
    if src:match("^https?://") then p.url = src else p.name = src end
    if opts.cc then p.cc = 1 end
    display(request("/convert", p), t, isMon)
  elseif cmd == "show" then
    local file = pos[2] or usage()
    local t, isMon = target()
    display(readFile(file), t, isMon)
  elseif cmd == "pull" then
    local name = pos[2] or usage()
    local t, isMon = target()
    display(request("/cci/" .. textutils.urlEncode(name)), t, isMon)
  elseif cmd == "put" then
    local file, name = pos[2] or usage(), pos[3] or usage()
    local text = readFile(file)
    parse(text)
    write(request("/cci/" .. textutils.urlEncode(name), nil, text))
  elseif cmd == "reset" then
    local t = target()
    resetPalette(t)
    t.setBackgroundColour(colours.black)
    t.clear()
  else
    usage()
  end
end

local ok, err = pcall(main)
if not ok and err ~= "" then
  if term.isColour() then term.setTextColour(colours.red) end
  print(err)
  term.setTextColour(colours.white)
end