--[[
    graph.lua - Real-time graphs on advanced monitors (CC:Tweaked)

    local Graph = require("graph")
    local g = Graph.new(peripheral.wrap("monitor_0"), 3, 2, 50, 15, 0, 100000, 0.33, 0.66)
    g:setUnit("RF")
    while true do
        g:addValue(myDetector.getTransferRate())
        g:show()
        sleep(0.05)
    end
]]

local Graph = {}
Graph.__index = Graph

-- locals: avoid global lookups inside the render loop
local floor  = math.floor
local rep    = string.rep
local concat = table.concat
local sformat = string.format

-- colour -> blit hex digit
local HEXDIGITS = "0123456789abcdef"
local COLOR_HEX = {}
do
    local c = 1
    for i = 1, 16 do
        COLOR_HEX[c] = HEXDIGITS:sub(i, i)
        c = c * 2
    end
end

local SI = { "", "K", "M", "G", "T", "P" }

--- 1234567 -> "1.23 M"  (+ unit)
local function shorten(v, unit)
    local sign = ""
    if v < 0 then sign = "-"; v = -v end
    local i = 1
    while v >= 1000 and i < #SI do
        v = v / 1000
        i = i + 1
    end
    local s
    if v < 10 then      s = sformat("%.2f", v)
    elseif v < 100 then s = sformat("%.1f", v)
    else                s = sformat("%.0f", v) end
    if s:find("%.", 1, false) then
        s = (s:gsub("0+$", ""))
        s = (s:gsub("%.$", ""))
    end
    local suffix = SI[i] .. (unit or "")
    if suffix == "" then return sign .. s end
    return sign .. s .. " " .. suffix
end
Graph.shorten = shorten

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

function Graph.new(screen, x, y, w, h, minV, maxV, lowT, highT)
    local self = setmetatable({}, Graph)

    self.screen = screen
    self.x      = floor(x or 1)
    self.y      = floor(y or 1)
    self.w      = math.max(1, floor(w or 20))
    self.h      = math.max(2, floor(h or 8))
    self.min    = minV or 0
    self.max    = maxV or 100
    self.lowT   = lowT  or 0.33
    self.highT  = highT or 0.66
    self.unit   = ""
    self.style  = "line"          -- "line" | "dot" | "bar"

    -- default colours (light fg / dark bg, as close as the CC palette allows;
    -- call :applyRecommendedPalette() to get proper dark tones)
    self.lowBg,  self.lowFg  = colors.red,   colors.pink
    self.midBg,  self.midFg  = colors.brown, colors.yellow
    self.highBg, self.highFg = colors.green, colors.lime
    self.axisColor = colors.white

    self:_allocBuffer(self.w)
    self:_recalcRange()
    return self
end

-- ring buffer, prefilled with zeros
function Graph:_allocBuffer(cap, keep)
    local old, oldN, oldPos, oldCap = self.buf, self.n or 0, self.pos or 0, self.cap or 0
    self.cap  = cap
    self.buf  = {}
    self.norm = {}
    for i = 1, cap do self.buf[i] = 0; self.norm[i] = 0 end
    self.n   = cap
    self.pos = cap                 -- index of the most recent value

    if keep and oldN > 0 then      -- re-inject the tail of the previous data
        local take = math.min(oldN, cap)
        for i = take - 1, 0, -1 do
            local idx = (oldPos - 1 - i) % oldCap + 1
            local dst = (cap - 1 - i) % cap + 1
            self.buf[dst] = old[idx]
        end
    end
    self._meta = nil
end

----------------------------------------------------------------------
-- range / normalisation
----------------------------------------------------------------------

function Graph:_recalcRange()
    local lo, hi = self.min, self.max
    local buf, n, pos, cap = self.buf, self.n, self.pos, self.cap
    for i = 0, n - 1 do
        local v = buf[(pos - n + i) % cap + 1]
        if v < lo then lo = v end
        if v > hi then hi = v end
    end
    if hi == lo then hi = lo + 1 end
    local changed = (lo ~= self.curMin) or (hi ~= self.curMax)
    self.curMin, self.curMax = lo, hi
    if changed then
        self._span = hi - lo
        self:_renormAll()
        self._meta = nil           -- labels + colour bands need rebuilding
    end
    return changed
end

function Graph:_renormAll()
    local buf, norm, span, lo = self.buf, self.norm, self._span, self.curMin
    for i = 1, self.cap do
        norm[i] = (buf[i] - lo) / span
    end
end

function Graph:_zoneFg(p)
    if p < self.lowT then return self.lowFg
    elseif p >= self.highT then return self.highFg
    else return self.midFg end
end

function Graph:_zoneBg(p)
    if p < self.lowT then return self.lowBg
    elseif p >= self.highT then return self.highBg
    else return self.midBg end
end

----------------------------------------------------------------------
-- data
----------------------------------------------------------------------

function Graph:addValue(v)
    v = tonumber(v) or 0
    local idx = self.pos % self.cap + 1
    self.buf[idx] = v
    self.pos = idx
    if not self:_recalcRange() then
        -- range unchanged: only the new sample needs normalising
        self.norm[idx] = (v - self.curMin) / self._span
    end
end

function Graph:clear(v)
    v = v or 0
    for i = 1, self.cap do self.buf[i] = v end
    self:_recalcRange()
    self:_renormAll()
    self._meta = nil
end

----------------------------------------------------------------------
-- render metadata (rebuilt only when geometry / range / colours change)
----------------------------------------------------------------------

function Graph:_buildMeta()
    local w, h = self.w, self.h
    local m = {}
    m.spaces  = rep(" ", w + 1)
    m.fgline  = rep("0", w + 1)
    m.axisHex = COLOR_HEX[self.axisColor] or "0"
    m.rowBg, m.bgLine = {}, {}
    for r = 1, h do
        local p = (h > 1) and (h - r) / (h - 1) or 0
        local hexc = COLOR_HEX[self:_zoneBg(p)] or "f"
        m.rowBg[r]  = hexc
        m.bgLine[r] = rep(hexc, w)
    end
    m.axisRow = rep(m.axisHex, w + 1)
    m.lblMax = shorten(self.curMax, self.unit):sub(1, w)
    m.lblMin = shorten(self.curMin, self.unit):sub(1, w)
    m.fgMax  = rep("0", #m.lblMax)
    m.fgMin  = rep("0", #m.lblMin)
    m.bgMax  = rep(m.rowBg[1], #m.lblMax)
    m.bgMin  = rep(m.rowBg[h], #m.lblMin)

    -- reusable scratch tables (no allocation per frame)
    local rp = {}
    for r = 1, h do rp[r] = { n = 0, col = {}, hex = {} } end
    self._rowPts = rp
    self._last   = {}
    self._parts  = {}
    self._meta   = m
end

----------------------------------------------------------------------
-- render
----------------------------------------------------------------------

local function addPt(t, col, hex)
    local k = t.n + 1
    t.n = k
    t.col[k] = col
    t.hex[k] = hex
end

function Graph:show()
    local sc = self.screen
    if not sc then return end
    if not self._meta then self:_buildMeta() end

    local m = self._meta
    local w, h, x, y = self.w, self.h, self.x, self.y
    local rowPts = self._rowPts
    for r = 1, h do rowPts[r].n = 0 end

    -- ---- plot points ------------------------------------------------
    local buf, norm, cap, pos, n = self.buf, self.norm, self.cap, self.pos, self.n
    local style = self.style
    local hm1 = h - 1
    local prevR
    local count = math.min(n, w)
    for i = 0, count - 1 do
        local idx = (pos - count + i) % cap + 1
        local p = norm[idx]
        if p < 0 then p = 0 elseif p > 1 then p = 1 end
        local r = h - floor(p * hm1 + 0.5)
        if r < 1 then r = 1 elseif r > h then r = h end
        local hex = COLOR_HEX[self:_zoneFg(p)] or "0"
        local col = i + 1
        if style == "bar" then
            for rr = r + 1, h do addPt(rowPts[rr], col, hex) end
        elseif style == "line" and prevR and prevR ~= r then
            local step = (prevR < r) and 1 or -1
            for rr = prevR + step, r - step, step do addPt(rowPts[rr], col, hex) end
        end
        addPt(rowPts[r], col, hex)
        prevR = r
    end

    -- ---- blit rows (one blit per row, skipped if unchanged) ---------
    local last, parts = self._last, self._parts
    local spaces, fgline = m.spaces, m.fgline
    for r = 1, h do
        local t = rowPts[r]
        local bgRow
        if t.n == 0 then
            bgRow = m.bgLine[r]
        else
            local bgc, cols, hexes = m.rowBg[r], t.col, t.hex
            local pn, lastc = 0, 0
            for k = 1, t.n do
                local c = cols[k]
                if c > lastc + 1 then
                    pn = pn + 1; parts[pn] = rep(bgc, c - lastc - 1)
                end
                pn = pn + 1; parts[pn] = hexes[k]
                lastc = c
            end
            if lastc < w then pn = pn + 1; parts[pn] = rep(bgc, w - lastc) end
            bgRow = concat(parts, "", 1, pn)
        end
        bgRow = m.axisHex .. bgRow           -- vertical axis merged into the row
        if bgRow ~= last[r] or r == 1 or r == h then
            last[r] = bgRow
            sc.setCursorPos(x - 1, y + r - 1)
            sc.blit(spaces, fgline, bgRow)
        end
    end

    -- ---- axis + labels ---------------------------------------------
    sc.setCursorPos(x - 1, y + h)
    sc.blit(spaces, fgline, m.axisRow)

    sc.setCursorPos(x, y)
    sc.blit(m.lblMax, m.fgMax, m.bgMax)
    sc.setCursorPos(x, y + h - 1)
    sc.blit(m.lblMin, m.fgMin, m.bgMin)
end

----------------------------------------------------------------------
-- getters / setters
----------------------------------------------------------------------

function Graph:getScreen() return self.screen end
function Graph:setScreen(s) self.screen = s; self._last = {} end

function Graph:getX() return self.x end
function Graph:setX(v) self.x = floor(v); self._last = {} end

function Graph:getY() return self.y end
function Graph:setY(v) self.y = floor(v); self._last = {} end

function Graph:getW() return self.w end
function Graph:setW(v)
    v = math.max(1, floor(v))
    if v == self.w then return end
    self.w = v
    self:_allocBuffer(v, true)
    self:_recalcRange()
    self:_renormAll()
    self._meta = nil
end

function Graph:getH() return self.h end
function Graph:setH(v)
    v = math.max(2, floor(v))
    if v == self.h then return end
    self.h = v
    self._meta = nil
end

function Graph:getMin() return self.min end
function Graph:setMin(v) self.min = v; self.curMin = nil; self:_recalcRange() end

function Graph:getMax() return self.max end
function Graph:setMax(v) self.max = v; self.curMax = nil; self:_recalcRange() end

--- currently displayed range (after auto-expansion)
function Graph:getRange() return self.curMin, self.curMax end

function Graph:getThresholds() return self.lowT, self.highT end
function Graph:setThresholds(lowT, highT)
    self.lowT, self.highT = lowT, highT
    self._meta = nil
end

function Graph:setLow(bg, fg)  self.lowBg, self.lowFg   = bg, fg; self._meta = nil end
function Graph:setMid(bg, fg)  self.midBg, self.midFg   = bg, fg; self._meta = nil end
function Graph:setHigh(bg, fg) self.highBg, self.highFg = bg, fg; self._meta = nil end
function Graph:setAxisColor(c) self.axisColor = c;               self._meta = nil end

function Graph:getUnit() return self.unit end
function Graph:setUnit(u) self.unit = u or ""; self._meta = nil end

function Graph:getStyle() return self.style end
function Graph:setStyle(s) self.style = s end

--- remaps red/brown/green to proper dark tones on this monitor
function Graph:applyRecommendedPalette()
    local sc = self.screen
    if not sc or not sc.setPaletteColour then return end
    sc.setPaletteColour(colors.red,   0x3A0E0E)   -- dark red
    sc.setPaletteColour(colors.pink,  0xFF6B6B)   -- light red
    sc.setPaletteColour(colors.brown, 0x3A3208)   -- dark yellow
    sc.setPaletteColour(colors.green, 0x0E3A16)   -- dark green
    self._last = {}
end

return Graph