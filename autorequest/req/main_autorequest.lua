-- autocraft.lua -- Autocraft continu Applied Energistics 2 via ME Bridge (Advanced Peripherals)
-- Materiel : ordinateur avance + moniteur avance + ME Bridge relie au reseau ME.
-- Fichiers (crees au premier lancement dans /autocraft) :
--   config.cfg : config globale, a editer a la main (relue a chaud)
--   items.cfg  : items suivis, ecrit par le programme, editable a la main (relu a chaud)
--   state.dat  : etat interne (mode, echecs, skips, requetes en cours) -- ne pas toucher
--   crash.log  : erreurs attrapees
-- Ctrl+T pour arreter.

local DIR = "/autocraft"
local CFG_PATH = DIR .. "/config.cfg"
local ITEMS_PATH = DIR .. "/items.cfg"
local STATE_PATH = DIR .. "/state.dat"
local LOG_PATH = DIR .. "/crash.log"

local DEFAULT_CFG = [[
{
  -- Pourcentage des CPUs de craft utilisables (les CPUs en PLAYER_ONLY sont exclus du calcul)
  jour = 50,
  nuit = 90,

  -- Taille de chaque requete : un batch a la fois, jusqu'a atteindre le min
  batch_items  = 64,   -- en items
  batch_fluids = 64,   -- en seaux (1 seau = 1000 mB)

  -- Echec : la requete n'apparait sur aucun CPU apres ce delai (secondes)
  timeout = 30,
  max_echecs = 3,

  -- Secondes entre deux scans du reseau
  intervalle = 5,

  -- Echelle du texte du moniteur (0.5 a 5)
  echelle = 1,

  -- Noms de peripheriques, laisser commente pour la detection automatique
  -- bridge = "meBridge_0",
  -- moniteur = "monitor_0",
}
]]

local DEFAULTS = {
  jour = 50, nuit = 90, batch_items = 64, batch_fluids = 64,
  timeout = 30, max_echecs = 3, intervalle = 5, echelle = 1,
}

---------------------------------------------------------------------------
-- Fichiers
---------------------------------------------------------------------------
local function readFile(p)
  local h = fs.open(p, "r")
  if not h then return nil end
  local s = h.readAll()
  h.close()
  return s
end

-- Ecriture atomique : on ecrit a cote puis on remplace, pour qu'un crash
-- ou un reboot en plein milieu ne laisse jamais un fichier a moitie ecrit.
local function writeAtomic(p, s)
  local tmp = p .. ".tmp"
  local h = fs.open(tmp, "w")
  if not h then return false end
  h.write(s)
  h.close()
  if fs.exists(p) then fs.delete(p) end
  fs.move(tmp, p)
  return true
end

local function recoverTmp(p)
  if not fs.exists(p) and fs.exists(p .. ".tmp") then fs.move(p .. ".tmp", p) end
end

local function mtime(p)
  if not fs.exists(p) then return nil end
  local ok, a = pcall(fs.attributes, p)
  if ok and type(a) == "table" then return a.modified end
  return nil
end

local function loadTableFile(p)
  local s = readFile(p)
  if not s then return nil, "fichier absent" end
  local f, err = load("return " .. s, "@" .. fs.getName(p), "t", {})
  if not f then return nil, err end
  local ok, t = pcall(f)
  if not ok then return nil, tostring(t) end
  if type(t) ~= "table" then return nil, "le fichier doit contenir une table { ... }" end
  return t
end

local function logCrash(msg)
  pcall(function()
    if not fs.exists(DIR) then fs.makeDir(DIR) end
    if fs.exists(LOG_PATH) and fs.getSize(LOG_PATH) > 16000 then fs.delete(LOG_PATH) end
    local h = fs.open(LOG_PATH, "a")
    if h then
      h.writeLine("[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. tostring(msg))
      h.close()
    end
  end)
end

---------------------------------------------------------------------------
-- Etat global (reinitialise a chaque (re)demarrage de main)
---------------------------------------------------------------------------
local cfg, cfgM
local tracked, byKey, itemsM, itemsErr
local rt            -- key -> { fails, skip, pending, retryAfter, stock, absent, onCpu, cpuAmount, dname }
local queue, inQueue
local mode
local net
local craftables
local ui
local bridge, mon, win, MW, MH
local dirty

local function now() return os.epoch("utc") / 1000 end

local function addLog(text, color) ui.log = { text, color or colors.lightGray } end

local function keyOf(kind, id) return kind .. ":" .. id end

local function getRt(key)
  local r = rt[key]
  if not r then r = { fails = 0 }; rt[key] = r end
  return r
end

---------------------------------------------------------------------------
-- Config globale
---------------------------------------------------------------------------
local function num(v, def, lo, hi)
  v = tonumber(v)
  if not v then return def end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local function loadConfig()
  recoverTmp(CFG_PATH)
  if not fs.exists(CFG_PATH) then writeAtomic(CFG_PATH, DEFAULT_CFG) end
  local t, err = loadTableFile(CFG_PATH)
  cfgM = mtime(CFG_PATH)
  if not t then
    addLog("config.cfg invalide : " .. tostring(err), colors.red)
    if cfg then return end
    t = {}
  end
  cfg = {
    jour = num(t.jour, DEFAULTS.jour, 0, 100),
    nuit = num(t.nuit, DEFAULTS.nuit, 0, 100),
    batch_items = math.floor(num(t.batch_items, DEFAULTS.batch_items, 1)),
    batch_fluids = math.floor(num(t.batch_fluids, DEFAULTS.batch_fluids, 1)),
    timeout = num(t.timeout, DEFAULTS.timeout, 5),
    max_echecs = math.floor(num(t.max_echecs, DEFAULTS.max_echecs, 1)),
    intervalle = num(t.intervalle, DEFAULTS.intervalle, 1),
    echelle = num(t.echelle, DEFAULTS.echelle, 0.5, 5),
    bridge = type(t.bridge) == "string" and t.bridge or nil,
    moniteur = type(t.moniteur) == "string" and t.moniteur or nil,
  }
end

---------------------------------------------------------------------------
-- Items suivis
---------------------------------------------------------------------------
local function serializeItems(list)
  local out = { "{" }
  for _, it in ipairs(list) do
    out[#out + 1] = string.format("  { type = %q, id = %q, min = %d, nuit = %s, name = %q },",
      it.kind, it.id, it.min, it.night and "true" or "false", it.name or it.id)
  end
  out[#out + 1] = "}"
  return table.concat(out, "\n") .. "\n"
end

local function setTracked(list)
  tracked, byKey = list, {}
  for _, it in ipairs(list) do byKey[it.key] = it end
end

local function loadItems()
  recoverTmp(ITEMS_PATH)
  if not fs.exists(ITEMS_PATH) then writeAtomic(ITEMS_PATH, "{\n}\n") end
  local t, err = loadTableFile(ITEMS_PATH)
  itemsM = mtime(ITEMS_PATH)
  if not t then
    itemsErr = "items.cfg invalide : " .. tostring(err)
    addLog(itemsErr, colors.red)
    if not tracked then setTracked({}) end
    return
  end
  local list, seen = {}, {}
  for _, e in ipairs(t) do
    if type(e) == "table" and type(e.id) == "string" and tonumber(e.min) and tonumber(e.min) > 0 then
      local kind = (e.type == "fluid") and "fluid" or "item"
      local key = keyOf(kind, e.id)
      if not seen[key] then
        seen[key] = true
        list[#list + 1] = {
          kind = kind, id = e.id, key = key, min = math.floor(tonumber(e.min)),
          name = type(e.name) == "string" and e.name or e.id,
          night = e.nuit == true,
        }
      end
    end
  end
  itemsErr = nil
  setTracked(list)
end

local function saveItems()
  if itemsErr then return false end
  writeAtomic(ITEMS_PATH, serializeItems(tracked))
  itemsM = mtime(ITEMS_PATH)
  return true
end

-- min et batch exprimes dans l'unite du ME (items, ou mB pour les fluides)
local function minUnits(it) return it.kind == "fluid" and it.min * 1000 or it.min end
local function batchUnits(it)
  return it.kind == "fluid" and cfg.batch_fluids * 1000 or cfg.batch_items
end

---------------------------------------------------------------------------
-- Etat persistant
---------------------------------------------------------------------------
local function loadState()
  recoverTmp(STATE_PATH)
  mode = "jour"
  rt = {}
  local s = readFile(STATE_PATH)
  local t = s and textutils.unserialize(s)
  if type(t) == "table" then
    if t.mode == "nuit" then mode = "nuit" end
    if type(t.rt) == "table" then
      for k, v in pairs(t.rt) do
        if type(k) == "string" and type(v) == "table" then
          local p = v.pending
          if type(p) ~= "table" or not tonumber(p.t) then p = nil end
          rt[k] = {
            fails = tonumber(v.fails) or 0, skip = v.skip == true, pending = p,
            retryAfter = tonumber(v.retryAfter),
          }
        end
      end
    end
  end
end

local function saveState()
  local out = {}
  for k, r in pairs(rt) do
    if byKey[k] and (r.fails > 0 or r.skip or r.pending or r.retryAfter) then
      out[k] = { fails = r.fails, skip = r.skip or nil, pending = r.pending, retryAfter = r.retryAfter }
    end
  end
  writeAtomic(STATE_PATH, textutils.serialize({ mode = mode, rt = out }))
  dirty = false
end

---------------------------------------------------------------------------
-- File d'attente (FIFO simple)
---------------------------------------------------------------------------
local function enqueue(key)
  if inQueue[key] then return end
  inQueue[key] = true
  queue[#queue + 1] = key
end

local function unqueue(key)
  if not inQueue[key] then return end
  inQueue[key] = nil
  for i = #queue, 1, -1 do if queue[i] == key then table.remove(queue, i) end end
end

---------------------------------------------------------------------------
-- Formatage
---------------------------------------------------------------------------
local function fmt(n)
  n = n or 0
  if n >= 1e12 then return string.format("%.1fT", n / 1e12)
  elseif n >= 1e9 then return string.format("%.1fG", n / 1e9)
  elseif n >= 1e6 then return string.format("%.1fM", n / 1e6)
  elseif n >= 1e4 then return string.format("%.1fk", n / 1e3)
  else return tostring(math.floor(n)) end
end

local function amt(kind, units)
  if kind == "fluid" then return fmt(math.floor((units or 0) / 1000)) .. "B" end
  return fmt(units)
end

local function label(it)
  local r = rt[it.key]
  return (r and r.dname) or it.name or it.id
end

---------------------------------------------------------------------------
-- ME Bridge
---------------------------------------------------------------------------
local function findBridge()
  if cfg.bridge then
    bridge = peripheral.isPresent(cfg.bridge) and peripheral.wrap(cfg.bridge) or nil
  else
    bridge = peripheral.find("meBridge")
  end
end

local function bcall(name, ...)
  if not bridge then return nil, "NO_BRIDGE" end
  local f = bridge[name]
  if type(f) ~= "function" then return nil, "methode " .. name .. " absente" end
  local ok, a, b = pcall(f, ...)
  if not ok then return nil, tostring(a) end
  return a, b
end

local function fail(it, reason)
  local r = getRt(it.key)
  r.pending = nil
  r.fails = r.fails + 1
  dirty = true
  if r.fails >= cfg.max_echecs then
    r.skip = true
    r.retryAfter = nil
    unqueue(it.key)
    addLog("SKIP " .. label(it) .. " (" .. reason .. ")", colors.red)
  else
    r.retryAfter = now() + cfg.timeout
    unqueue(it.key)
    enqueue(it.key) -- fin de file
    addLog("Echec " .. r.fails .. "/" .. cfg.max_echecs .. " " .. label(it) .. " : " .. reason, colors.orange)
  end
end

local function scan()
  if not bridge then findBridge() end
  if not bridge then
    net.online, net.err = false, "ME Bridge introuvable"
    return
  end
  local con = bcall("isConnected")
  if con ~= true then
    net.online = false
    if con == nil then
      net.err = "ME Bridge injoignable"
      bridge = nil
    else
      net.err = "Reseau ME hors ligne"
    end
    return
  end

  local cpus, e1 = bcall("getCraftingCPUs")
  local itemsL, e2 = bcall("listCraftableItems")
  local fluidsL, e3 = bcall("listCraftableFluid")
  if type(cpus) ~= "table" or type(itemsL) ~= "table" or type(fluidsL) ~= "table" then
    net.online, net.err = false, "Lecture ME : " .. tostring(e1 or e2 or e3)
    return
  end
  net.online, net.err = true, nil
  local t = now()

  -- Items qui ont une requete a nous en cours (pour colorer les CPUs)
  local ours = {}
  for k, r in pairs(rt) do
    local it = byKey[k]
    if it and r.pending then ours[it.id] = true end
  end

  -- CPUs
  local onCpu = {}
  local elig, busy, manual = 0, 0, 0
  local list = {}
  for _, c in ipairs(cpus) do
    local po = c.selectionMode == "PLAYER_ONLY"
    local job = c.craftingJob
    local jname, jamount
    if type(job) == "table" and type(job.storage) == "table" and type(job.storage.name) == "string" then
      jname, jamount = job.storage.name, tonumber(job.storage.amount) or 0
      onCpu[jname] = (onCpu[jname] or 0) + jamount
    end
    local isBusy = c.isBusy == true or jname ~= nil
    local mine = isBusy and jname ~= nil and ours[jname] == true
    if not po then
      elig = elig + 1
      if isBusy then
        busy = busy + 1
        if not mine then manual = manual + 1 end
      end
    end
    list[#list + 1] = { po = po, busy = isBusy, mine = mine }
  end
  table.sort(list, function(a, b) return (a.po and 1 or 0) < (b.po and 1 or 0) end)
  net.cpus = list

  -- Stocks + liste des craftables pour la recherche
  local stock = { item = {}, fluid = {} }
  local cl, seen = {}, {}
  local function ingest(src, kind)
    for _, s in ipairs(src) do
      if type(s) == "table" and type(s.name) == "string" then
        stock[kind][s.name] = (stock[kind][s.name] or 0) + (tonumber(s.amount) or 0)
        local k = keyOf(kind, s.name)
        if not seen[k] then
          seen[k] = true
          local dn = type(s.displayName) == "string" and s.displayName or s.name
          cl[#cl + 1] = { id = s.name, name = dn, lname = dn:lower(), kind = kind, key = k }
        end
      end
    end
  end
  ingest(itemsL, "item")
  ingest(fluidsL, "fluid")
  table.sort(cl, function(a, b) return a.lname < b.lname end)
  craftables = cl
  local dnames = {}
  for _, e in ipairs(cl) do dnames[e.key] = e.name end

  -- Producteur : etat de chaque item suivi
  local snapshot = {}
  for i, it in ipairs(tracked) do snapshot[i] = it end
  for _, it in ipairs(snapshot) do
    local r = getRt(it.key)
    local s = stock[it.kind][it.id]
    r.dname = dnames[it.key]
    if s == nil then
      -- plus de pattern pour cet item : on ne demande rien
      r.absent, r.stock, r.onCpu = true, 0, false
      unqueue(it.key)
    else
      r.absent, r.stock = false, s
      local mu = minUnits(it)
      local crafting = onCpu[it.id] ~= nil
      r.onCpu, r.cpuAmount = crafting, onCpu[it.id]
      local p = r.pending
      if p then
        if crafting then
          if not p.seen then p.seen = true; dirty = true end
        elseif p.seen or s >= (p.before or 0) + (p.amount or 0) or s >= mu then
          r.pending, r.fails, r.retryAfter = nil, 0, nil
          dirty = true
          addLog("Termine : " .. amt(it.kind, p.amount) .. " " .. label(it), colors.lime)
        elseif t - p.t > cfg.timeout then
          fail(it, "aucun CPU apres " .. math.floor(cfg.timeout) .. "s")
        end
      end
      r.waitNight = false
      if r.skip or r.pending or crafting then
        unqueue(it.key)
      elseif s < mu then
        if it.night and mode ~= "nuit" then
          -- item "nuit seulement" : on attend le mode nuit
          r.waitNight = true
          unqueue(it.key)
        else
          enqueue(it.key)
        end
      else
        unqueue(it.key)
        if r.fails > 0 then r.fails, r.retryAfter = 0, nil; dirty = true end
      end
    end
  end

  -- Consommateur : on remplit jusqu'au cap
  local pend = 0
  for k, r in pairs(rt) do
    if byKey[k] and r.pending and not r.pending.seen then pend = pend + 1 end
  end
  local cap = math.floor(elig * cfg[mode] / 100)
  local used = busy + pend
  local n = #queue
  for _ = 1, n do
    if used >= cap or #queue == 0 then break end
    local key = table.remove(queue, 1)
    inQueue[key] = nil
    local it, r = byKey[key], rt[key]
    if it and it.night and mode ~= "nuit" then
      if r then r.waitNight = true end -- passe en jour entre deux scans : on le sort de la file
    elseif it and r and not r.skip and not r.pending and not r.absent and not r.onCpu then
      if r.retryAfter and t < r.retryAfter then
        enqueue(key) -- pas encore, on le remet au bout
      else
        local missing = minUnits(it) - (r.stock or 0)
        if missing > 0 then
          -- une requete = un seul batch ; s'il manque encore apres, l'item
          -- repasse en fin de file au scan suivant
          local amount = math.min(batchUnits(it), 2147483647)
          local fn = it.kind == "fluid" and "craftFluid" or "craftItem"
          local ok, err = bcall(fn, { name = it.id, count = amount })
          if ok == true then
            r.pending = { t = t, amount = amount, before = r.stock or 0, seen = false }
            r.retryAfter = nil
            dirty = true
            used = used + 1
            pend = pend + 1
            addLog("Requete : " .. amt(it.kind, amount) .. " " .. label(it), colors.lightBlue)
          else
            fail(it, tostring(err or "refuse"))
          end
        end
      end
    end
  end

  net.elig, net.busy, net.manual, net.pend, net.cap = elig, busy, manual, pend, cap
  net.lastScan = t
end

---------------------------------------------------------------------------
-- Moniteur : primitives
---------------------------------------------------------------------------
local buttons = {}

local function fit(s, w)
  if w <= 0 then return "" end
  if #s > w then return s:sub(1, math.max(1, w - 1)) .. "." end
  return s .. string.rep(" ", w - #s)
end
local function at(x, y, text, fg, bg)
  win.setCursorPos(x, y)
  if bg then win.setBackgroundColor(bg) end
  if fg then win.setTextColor(fg) end
  win.write(text)
end
local function fill(x, y, w, bg)
  if w <= 0 then return end
  win.setCursorPos(x, y); win.setBackgroundColor(bg); win.write(string.rep(" ", w))
end
local function seq(x, y, parts)
  for _, p in ipairs(parts) do at(x, y, p[1], p[2], colors.black); x = x + #p[1] end
  return x
end
local function button(x, y, text, fg, bg, fn)
  at(x, y, text, fg, bg)
  buttons[#buttons + 1] = { x1 = x, y1 = y, x2 = x + #text - 1, y2 = y, fn = fn }
end
local function zone(x1, y1, x2, y2, fn)
  buttons[#buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, fn = fn }
end

local function findMonitor()
  if cfg.moniteur then
    mon = peripheral.isPresent(cfg.moniteur) and peripheral.wrap(cfg.moniteur) or nil
  else
    mon = peripheral.find("monitor", function(_, m) return m.isColor() end)
  end
  if mon then
    mon.setTextScale(cfg.echelle)
    MW, MH = mon.getSize()
    win = window.create(mon, 1, 1, MW, MH, false)
  else
    win = nil
  end
end

---------------------------------------------------------------------------
-- Moniteur : vues
---------------------------------------------------------------------------
local function toggleMode()
  mode = (mode == "jour") and "nuit" or "jour"
  saveState()
  addLog("Mode " .. mode:upper() .. " : " .. cfg[mode] .. "% des CPUs",
    mode == "jour" and colors.yellow or colors.lightBlue)
end

local function drawHeader()
  fill(1, 1, MW, colors.gray)
  at(2, 1, "AE2 AUTOCRAFT", colors.white, colors.gray)
  local x = 16
  for _, tb in ipairs({ { "suivi", " SUIVI " }, { "recherche", " RECHERCHE " } }) do
    local on = ui.tab == tb[1]
    button(x, 1, tb[2], on and colors.black or colors.lightGray, on and colors.white or colors.gray,
      function() ui.tab = tb[1] end)
    x = x + #tb[2] + 1
  end
  local jour = mode == "jour"
  local lb = (jour and " JOUR " or " NUIT ") .. cfg[mode] .. "% "
  button(MW - #lb, 1, lb, jour and colors.black or colors.white, jour and colors.yellow or colors.blue, toggleMode)
  if not net.online then
    fill(1, 2, MW, colors.red)
    at(2, 2, fit((net.err or "Hors ligne") .. " - nouvel essai a chaque scan", MW - 2), colors.white, colors.red)
  end
end

-- Gauge CPU a longueur fixe : chaque couleur occupe une part proportionnelle
-- au nombre de CPUs, quel que soit leur nombre.
--   rouge  = CPU utilise (hors PLAYER_ONLY)
--   vert   = CPU libre utilisable (dans le ratio du mode)
--   gris   = CPU libre hors ratio
--   orange = CPU PLAYER_ONLY
local function drawCpu()
  local elig, busy, pend, cap = net.elig or 0, net.busy or 0, net.pend or 0, net.cap or 0
  local po = 0
  for _, c in ipairs(net.cpus) do if c.po then po = po + 1 end end
  local free = math.max(0, elig - busy)
  -- une requete en calcul reserve deja une place dans le ratio
  local green = math.min(free, math.max(0, cap - busy - pend))
  local grey = free - green

  at(2, 3, "CPU", colors.white, colors.black)
  local x0, w = 6, MW - 6
  local parts = {
    { busy, colors.red }, { green, colors.lime }, { grey, colors.gray }, { po, colors.orange },
  }
  local total = busy + green + grey + po
  if total == 0 or w < 4 then
    at(x0, 3, "aucun CPU", colors.gray, colors.black)
  else
    -- largeurs proportionnelles, au moins 1 colonne pour chaque categorie non vide
    local widths, sum = {}, 0
    for i, p in ipairs(parts) do
      local wi = math.floor(p[1] / total * w + 0.5)
      if p[1] > 0 and wi == 0 then wi = 1 end
      widths[i] = wi
      sum = sum + wi
    end
    -- on corrige l'arrondi sur le plus gros segment
    while sum ~= w do
      local big = 1
      for i = 2, #widths do if widths[i] > widths[big] then big = i end end
      if sum < w then
        widths[big], sum = widths[big] + 1, sum + 1
      elseif widths[big] > 1 then
        widths[big], sum = widths[big] - 1, sum - 1
      else
        break
      end
    end
    local x = x0
    for i, p in ipairs(parts) do
      fill(x, 3, widths[i], p[2])
      x = x + widths[i]
    end
  end

  local legend = {
    { "Util " .. busy, colors.red },
    { "  Libre " .. green, colors.lime },
    { "  Hors " .. grey, colors.lightGray },
    { "  Joueur " .. po, colors.orange },
  }
  if pend > 0 then legend[#legend + 1] = { "  Calcul " .. pend, colors.lightBlue } end
  local nx = seq(2, 4, legend)
  if busy + pend > cap and nx + 8 <= MW then at(nx + 1, 4, "ATTENTE", colors.red, colors.black) end
end

-- etat affiche d'un item : code, libelle, couleur, priorite de tri
local function itemState(it)
  local r = rt[it.key] or { fails = 0 }
  if r.skip then return "skip", "SKIP>TOUCH", colors.white, 1 end
  if r.absent then return "err", "PATTERN?", colors.red, 2 end
  if r.pending and not r.pending.seen then return "craft", "CALCUL", colors.lightBlue, 4 end
  if r.onCpu then
    local a = (r.pending and r.pending.amount) or r.cpuAmount
    return "craft", "CRAFT " .. amt(it.kind, a), colors.lightBlue, 4
  end
  if inQueue[it.key] then
    if r.fails > 0 then return "file", "RETRY " .. r.fails .. "/" .. cfg.max_echecs, colors.orange, 3 end
    return "file", "EN FILE", colors.yellow, 5
  end
  if r.waitNight then return "nuit", "ATT. NUIT", colors.blue, 6 end
  if r.stock == nil then return "ok", "?", colors.gray, 9 end
  return "ok", "OK", colors.lime, 9
end

local function segBar(x, y, w, parts)
  local total = 0
  for _, p in ipairs(parts) do total = total + p[1] end
  if total == 0 then fill(x, y, w, colors.gray) return end
  local acc, pos = 0, x
  for _, p in ipairs(parts) do
    acc = acc + p[1]
    local e = x + math.floor(acc / total * w + 0.5)
    if e > pos then fill(pos, y, e - pos, p[2]); pos = e end
  end
end

local function pager(y, page, pages, setPage)
  button(2, y, " \17 ", colors.white, colors.gray, function() setPage(math.max(1, page - 1)) end)
  at(6, y, fit(page .. "/" .. pages, 5), colors.white, colors.black)
  button(11, y, " \16 ", colors.white, colors.gray, function() setPage(math.min(pages, page + 1)) end)
  at(15, y, fit(ui.log[1], MW - 15), ui.log[2], colors.black)
end

local function drawSuivi()
  drawCpu()

  local counts = { ok = 0, craft = 0, file = 0, err = 0, nuit = 0 }
  local shown = {}
  for i, it in ipairs(tracked) do
    local code, lb, col, prio = itemState(it)
    if code == "skip" then code = "err" end
    counts[code] = counts[code] + 1
    if code ~= "ok" then shown[#shown + 1] = { it = it, lb = lb, col = col, prio = prio, i = i } end
  end
  table.sort(shown, function(a, b)
    if a.prio ~= b.prio then return a.prio < b.prio end
    return a.i < b.i
  end)

  segBar(2, 6, MW - 2, {
    { counts.ok, colors.lime }, { counts.craft, colors.lightBlue },
    { counts.file, colors.yellow }, { counts.nuit, colors.blue }, { counts.err, colors.red },
  })
  seq(2, 7, {
    { "OK " .. counts.ok, colors.lime }, { "  Craft " .. counts.craft, colors.lightBlue },
    { "  File " .. counts.file, colors.yellow }, { "  Nuit " .. counts.nuit, colors.blue },
    { "  Err " .. counts.err, colors.red },
    { "  Batch " .. cfg.batch_items .. "/" .. cfg.batch_fluids .. "B", colors.lightGray },
  })
  at(1, 8, string.rep("\140", MW), colors.gray, colors.black)

  local barW = math.max(6, math.floor(MW * 0.15))
  local numW, stW = 13, 10
  local nameW = MW - 2 - barW - numW - stW - 3
  local bx = 2 + nameW + 1
  local nx = bx + barW + 1
  local sx = nx + numW + 1
  at(2, 9, fit("EN COURS / ERREURS", nameW), colors.gray, colors.black)
  at(bx, 9, "STOCK", colors.gray, colors.black)
  at(nx, 9, "    STOCK/MIN", colors.gray, colors.black)
  at(sx, 9, "ETAT", colors.gray, colors.black)

  local top, bottom = 10, MH - 1
  local per = math.max(1, bottom - top + 1)
  local pages = math.max(1, math.ceil(#shown / per))
  ui.pageSuivi = math.min(ui.pageSuivi, pages)

  if #shown == 0 then
    local msg = #tracked == 0 and "Aucun item suivi - tapez sur l'ordinateur pour en ajouter"
      or ("Tout est en stock (" .. #tracked .. " items suivis)")
    at(math.max(2, math.floor((MW - #msg) / 2) + 1), math.floor((top + bottom) / 2), fit(msg, MW - 2),
      #tracked == 0 and colors.lightGray or colors.lime, colors.black)
  end

  local first = (ui.pageSuivi - 1) * per + 1
  for row = 0, per - 1 do
    local e = shown[first + row]
    if not e then break end
    local it, r = e.it, rt[e.it.key] or {}
    local y = top + row
    local skip = r.skip == true
    local rowBg = skip and colors.red or colors.black
    fill(1, y, MW, rowBg)
    local nm = (it.kind == "fluid" and "~" or "") .. label(it)
    at(2, y, fit(nm, nameW), it.kind == "fluid" and colors.cyan or colors.white, rowBg)
    local mu = minUnits(it)
    local frac = math.min(1, (r.stock or 0) / mu)
    local nf = math.floor(frac * barW + 0.5)
    local bc = frac >= 1 and colors.lime or (frac >= 0.5 and colors.yellow or colors.red)
    if skip then bc = colors.white end
    fill(bx, y, barW, colors.gray)
    if nf > 0 then fill(bx, y, nf, bc) end
    local numTxt = amt(it.kind, r.stock or 0) .. "/" .. amt(it.kind, mu)
    at(nx, y, string.rep(" ", math.max(0, numW - #numTxt)) .. numTxt, colors.lightGray, rowBg)
    at(sx, y, fit(e.lb, stW), e.col, rowBg)
    if skip then
      zone(1, y, MW, y, function()
        r.skip, r.fails, r.retryAfter = false, 0, nil
        saveState()
        addLog("Relance : " .. label(it), colors.yellow)
      end)
    end
  end
  pager(MH, ui.pageSuivi, pages, function(p) ui.pageSuivi = p end)
end

local function filtered()
  local q, res = ui.query:lower(), {}
  for _, e in ipairs(craftables) do
    if q == "" or e.lname:find(q, 1, true) then res[#res + 1] = e end
  end
  return res
end

local function drawRecherche()
  at(2, 3, "Recherche (clavier de l'ordinateur) :", colors.lightGray, colors.black)
  fill(2, 4, MW - 2, colors.gray)
  at(3, 4, fit(ui.query .. "_", MW - 4), colors.white, colors.gray)
  local res = filtered()
  local hint = ui.edit and "  > saisie du min sur l'ordinateur" or "  touchez pour suivre/modifier"
  seq(2, 5, { { #res .. " craftable(s)", colors.white }, { hint, ui.edit and colors.yellow or colors.gray } })
  at(1, 6, string.rep("\140", MW), colors.gray, colors.black)

  local colW = (MW >= 80) and math.floor((MW - 2) / 2) or (MW - 2)
  local ncols = math.max(1, math.floor((MW - 2) / colW))
  local top, bottom = 7, MH - 1
  local rows = math.max(1, bottom - top + 1)
  local per = rows * ncols
  local pages = math.max(1, math.ceil(#res / per))
  ui.pageRech = math.min(ui.pageRech, pages)

  if #craftables == 0 then
    at(2, top, net.online and "Aucun craftable dans le reseau." or "Pas de donnees (reseau hors ligne).",
      colors.gray, colors.black)
  end

  local first = (ui.pageRech - 1) * per + 1
  for i = 0, per - 1 do
    local e = res[first + i]
    if not e then break end
    local col, row = math.floor(i / rows), i % rows
    local x, y = 2 + col * colW, top + row
    local tr = byKey[e.key]
    local tag = tr and (" [suivi " .. amt(tr.kind, minUnits(tr)) .. (tr.night and " N" or "") .. "]") or ""
    local sel = ui.edit and ui.edit.key == e.key
    local bg = sel and colors.white or colors.black
    local nm = (e.kind == "fluid" and "~" or "") .. e.name
    at(x, y, fit(nm, colW - 1 - #tag), sel and colors.black or (e.kind == "fluid" and colors.cyan or colors.white), bg)
    at(x + colW - 1 - #tag, y, tag, sel and colors.green or colors.lime, bg)
    zone(x, y, x + colW - 2, y, function()
      ui.edit = e
      ui.editBuf = tr and tostring(tr.min) or ""
      ui.editNight = tr and tr.night or false
    end)
  end
  pager(MH, ui.pageRech, pages, function(p) ui.pageRech = p end)
end

---------------------------------------------------------------------------
-- Terminal de l'ordinateur
---------------------------------------------------------------------------
local function tc(c) if term.isColor() then term.setTextColor(c) end end

local function drawTerm()
  local w = term.getSize()
  term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
  tc(colors.yellow); print("AE2 AUTOCRAFT")
  tc(colors.gray); print(string.rep("-", w))
  if net.online then
    tc(colors.lime); print("Reseau : EN LIGNE")
  else
    tc(colors.red); print("Reseau : " .. (net.err or "hors ligne"))
  end
  tc(colors.white)
  print("Mode   : " .. mode:upper() .. " " .. cfg[mode] .. "%  (cap " ..
    ((net.busy or 0) + (net.pend or 0)) .. "/" .. (net.cap or 0) .. " CPU)")
  print("Suivis : " .. #tracked .. "   En file : " .. #queue)
  if itemsErr then tc(colors.red); print(itemsErr) end
  if not mon then tc(colors.red); print("Aucun moniteur avance trouve") end
  print("")
  if ui.edit then
    local e = ui.edit
    tc(colors.white); print("Item : " .. e.name)
    tc(colors.gray); print("ID   : " .. e.id)
    tc(colors.white)
    term.write("Stock min" .. (e.kind == "fluid" and " (seaux)" or "") .. " : ")
    tc(colors.lime); term.write(ui.editBuf .. "_"); print("")
    tc(colors.white); term.write("Nuit seulement : ")
    if ui.editNight then tc(colors.lightBlue); print("OUI") else tc(colors.lightGray); print("NON") end
    tc(colors.lightGray)
    print("Entree = valider   0 = retirer   vide = annuler")
    print("Tab = basculer nuit seulement")
  else
    tc(colors.white); term.write("Recherche : "); tc(colors.lime); term.write(ui.query .. "_"); print("")
    tc(colors.lightGray)
    print("Tapez pour filtrer, puis touchez un item")
    print("sur le moniteur. Ctrl+T pour arreter.")
  end
end

local function redraw()
  buttons = {}
  if win then
    local ok, err = pcall(function()
      win.setVisible(false)
      win.setBackgroundColor(colors.black); win.clear()
      drawHeader()
      if ui.tab == "suivi" then drawSuivi() else drawRecherche() end
      win.setVisible(true)
    end)
    if not ok then
      logCrash("dessin moniteur : " .. tostring(err))
      mon, win = nil, nil
    end
  end
  drawTerm()
end

---------------------------------------------------------------------------
-- Edition depuis le clavier
---------------------------------------------------------------------------
local function commitEdit()
  local e = ui.edit
  local buf = ui.editBuf
  local night = ui.editNight == true
  ui.edit, ui.editBuf, ui.editNight = nil, "", false
  if buf == "" then return end
  if itemsErr then
    addLog("items.cfg invalide : corrige-le avant d'ajouter des items", colors.red)
    return
  end
  local n = tonumber(buf) or 0
  local tr = byKey[e.key]
  if n == 0 then
    if tr then
      local list = {}
      for _, it in ipairs(tracked) do if it.key ~= e.key then list[#list + 1] = it end end
      setTracked(list)
      unqueue(e.key)
      rt[e.key] = nil
      saveItems(); saveState()
      addLog("Retire du suivi : " .. e.name, colors.lightGray)
    end
    return
  end
  if tr then
    tr.min = n
    tr.night = night
    if night and mode ~= "nuit" then unqueue(e.key) end
    local r = rt[e.key]
    if r then r.fails, r.skip, r.retryAfter = 0, false, nil end
    addLog("Modifie : " .. e.name .. " min " .. amt(tr.kind, minUnits(tr)) .. (night and " (nuit)" or ""),
      colors.white)
  else
    local it = { kind = e.kind, id = e.id, key = e.key, min = n, name = e.name, night = night }
    local list = {}
    for _, x in ipairs(tracked) do list[#list + 1] = x end
    list[#list + 1] = it
    setTracked(list)
    addLog("Ajoute : " .. e.name .. " min " .. amt(it.kind, minUnits(it)), colors.lime)
  end
  saveItems(); saveState()
end

---------------------------------------------------------------------------
-- Boucles
---------------------------------------------------------------------------
local function worker()
  while true do
    if mtime(CFG_PATH) ~= cfgM then
      local oldScale = cfg.echelle
      loadConfig()
      addLog("config.cfg recharge", colors.lightGray)
      if cfg.echelle ~= oldScale then findMonitor() end
    end
    if mtime(ITEMS_PATH) ~= itemsM then
      loadItems()
      if not itemsErr then addLog("items.cfg recharge (" .. #tracked .. " items)", colors.lightGray) end
    end
    local ok, err = pcall(scan)
    if not ok then
      net.online, net.err = false, "Erreur scan"
      logCrash("scan : " .. tostring(err))
      addLog("Erreur scan : " .. tostring(err), colors.red)
      bridge = nil
    end
    if dirty then pcall(saveState) end
    os.queueEvent("autocraft_redraw")
    sleep(cfg.intervalle)
  end
end

local function interface()
  redraw()
  while true do
    local ev = { os.pullEvent() }
    local name = ev[1]
    local draw = true
    if name == "monitor_touch" then
      if mon and ev[2] == peripheral.getName(mon) then
        local x, y = ev[3], ev[4]
        for i = #buttons, 1, -1 do
          local b = buttons[i]
          if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then b.fn(); break end
        end
      end
    elseif name == "char" then
      if ui.edit then
        if ev[2]:match("%d") and #ui.editBuf < 9 then ui.editBuf = ui.editBuf .. ev[2] end
      else
        ui.query = ui.query .. ev[2]; ui.tab = "recherche"; ui.pageRech = 1
      end
    elseif name == "key" then
      if ev[2] == keys.backspace then
        if ui.edit then ui.editBuf = ui.editBuf:sub(1, -2)
        else ui.query = ui.query:sub(1, -2); ui.pageRech = 1 end
      elseif ev[2] == keys.enter or ev[2] == keys.numPadEnter then
        if ui.edit then commitEdit() end
      elseif ev[2] == keys.tab and ui.edit then
        ui.editNight = not ui.editNight
      else
        draw = false
      end
    elseif name == "monitor_resize" then
      if mon then MW, MH = mon.getSize(); win.reposition(1, 1, MW, MH) end
    elseif name == "peripheral" or name == "peripheral_detach" then
      if not mon or (name == "peripheral_detach" and ev[2] == peripheral.getName(mon)) then findMonitor() end
      if name == "peripheral_detach" and bridge and ev[2] == peripheral.getName(bridge) then bridge = nil end
    elseif name ~= "autocraft_redraw" then
      draw = false
    end
    if draw then redraw() end
  end
end

local function main()
  if not fs.exists(DIR) then fs.makeDir(DIR) end
  ui = { tab = "suivi", pageSuivi = 1, pageRech = 1, query = "", edit = nil, editBuf = "",
         log = { "Demarrage", colors.lightGray } }
  net = { online = false, err = "Premier scan...", cpus = {} }
  craftables, queue, inQueue = {}, {}, {}
  tracked, byKey, cfg, bridge, mon, win = nil, nil, nil, nil, nil, nil
  dirty = false
  loadConfig()
  loadItems()
  loadState()
  findMonitor()
  findBridge()
  parallel.waitForAny(worker, interface)
end

-- Boucle anti-crash : toute erreur est loguee et le programme redemarre.
while true do
  local ok, err = xpcall(main, debug.traceback)
  if ok then break end
  if tostring(err):find("Terminated", 1, true) then
    term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
    print("Autocraft arrete.")
    break
  end
  logCrash(err)
  term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
  printError(err)
  print("Redemarrage dans 5 s... (Ctrl+T pour arreter)")
  sleep(5)
end