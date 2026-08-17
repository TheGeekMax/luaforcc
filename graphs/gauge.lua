--[[
    gauge.lua - Vertical fill gauges on advanced monitors (CC:Tweaked)

    local Gauge = require("gauge")
    local gg = Gauge.new(monitor, 3, 2, 5, 20, 0, 100)
    gg:setFG(colors.lime)
    gg:setValue(42)
    gg:show()

    Layout: a 1-cell border frames the widget; the inner area (w-2 x h-2)
    fills from the bottom up with FG, the remainder stays BG.
]]

local Gauge = {}
Gauge.__index = Gauge

local floor = math.floor
local rep   = string.rep

local HEXDIGITS = "0123456789abcdef"
local COLOR_HEX = {}
do
    local c = 1
    for i = 1, 16 do
        COLOR_HEX[c] = HEXDIGITS:sub(i, i)
        c = c * 2
    end
end

----------------------------------------------------------------------
-- construction
----------------------------------------------------------------------

function Gauge.new(screen, x, y, w, h, minV, maxV)
    local self = setmetatable({}, Gauge)

    self.screen = screen
    self.x   = floor(x or 1)
    self.y   = floor(y or 1)
    self.w   = math.max(3, floor(w or 5))
    self.h   = math.max(3, floor(h or 10))
    self.min = minV or 0
    self.max = maxV or 100
    if self.max == self.min then self.max = self.min + 1 end

    self.bg     = colors.red     -- empty part  (call :applyRecommendedPalette for a true dark red)
    self.fg     = colors.pink    -- filled part
    self.border = colors.white

    self.value = self.min
    self.ratio = 0

    self._dirty      = true      -- full repaint needed
    self._lastFilled = nil       -- inner rows currently filled
    return self
end

----------------------------------------------------------------------
-- internals
----------------------------------------------------------------------

function Gauge:_buildMeta()
    local w, h = self.w, self.h
    local bH = COLOR_HEX[self.border] or "0"
    local fH = COLOR_HEX[self.fg]     or "0"
    local gH = COLOR_HEX[self.bg]     or "f"
    local inner = w - 2

    self._meta = {
        spaces    = rep(" ", w),
        fgline    = rep("0", w),
        borderRow = rep(bH, w),
        rowFull   = bH .. rep(fH, inner) .. bH,
        rowEmpty  = bH .. rep(gH, inner) .. bH,
        innerH    = h - 2,
    }
end

function Gauge:_filledRows()
    local innerH = self.h - 2
    local n = floor(self.ratio * innerH + 0.5)
    if n < 0 then n = 0 elseif n > innerH then n = innerH end
    return n
end

----------------------------------------------------------------------
-- value
----------------------------------------------------------------------

function Gauge:setValue(v)
    v = tonumber(v) or self.min
    if v < self.min then v = self.min elseif v > self.max then v = self.max end
    self.value = v
    self.ratio = (v - self.min) / (self.max - self.min)
end

function Gauge:getValue() return self.value end
function Gauge:getRatio() return self.ratio end

----------------------------------------------------------------------
-- render
----------------------------------------------------------------------

function Gauge:show()
    local sc = self.screen
    if not sc then return end
    if not self._meta then self:_buildMeta() end

    local m = self._meta
    local x, y, h = self.x, self.y, self.h
    local spaces, fgline = m.spaces, m.fgline
    local filled = self:_filledRows()

    if self._dirty then
        -- full repaint: top border, inner rows, bottom border
        sc.setCursorPos(x, y)
        sc.blit(spaces, fgline, m.borderRow)
        for r = 2, h - 1 do
            sc.setCursorPos(x, y + r - 1)
            sc.blit(spaces, fgline, (h - r <= filled) and m.rowFull or m.rowEmpty)
        end
        sc.setCursorPos(x, y + h - 1)
        sc.blit(spaces, fgline, m.borderRow)
        self._dirty = false
    elseif filled ~= self._lastFilled then
        -- only the rows that crossed the fill line need redrawing
        local a, b = self._lastFilled, filled
        local lo, hi = (a < b) and a or b, (a < b) and b or a
        local row = (b > a) and m.rowFull or m.rowEmpty
        for fromBottom = lo + 1, hi do
            sc.setCursorPos(x, y + h - fromBottom - 1)
            sc.blit(spaces, fgline, row)
        end
    end

    self._lastFilled = filled
end

--- force a full repaint on the next show() (e.g. after clearing the screen)
function Gauge:invalidate() self._dirty = true end

----------------------------------------------------------------------
-- getters / setters
----------------------------------------------------------------------

function Gauge:getScreen() return self.screen end
function Gauge:setScreen(s) self.screen = s; self._dirty = true end

function Gauge:getX() return self.x end
function Gauge:setX(v) self.x = floor(v); self._dirty = true end

function Gauge:getY() return self.y end
function Gauge:setY(v) self.y = floor(v); self._dirty = true end

function Gauge:getW() return self.w end
function Gauge:setW(v)
    v = math.max(3, floor(v))
    if v == self.w then return end
    self.w = v; self._meta = nil; self._dirty = true
end

function Gauge:getH() return self.h end
function Gauge:setH(v)
    v = math.max(3, floor(v))
    if v == self.h then return end
    self.h = v; self._meta = nil; self._dirty = true
    self:setValue(self.value)
end

function Gauge:getMin() return self.min end
function Gauge:setMin(v)
    self.min = v
    if self.max == self.min then self.max = self.min + 1 end
    self:setValue(self.value); self._dirty = true
end

function Gauge:getMax() return self.max end
function Gauge:setMax(v)
    self.max = v
    if self.max == self.min then self.max = self.min + 1 end
    self:setValue(self.value); self._dirty = true
end

function Gauge:getBG() return self.bg end
function Gauge:setBG(c) self.bg = c; self._meta = nil; self._dirty = true end

function Gauge:getFG() return self.fg end
function Gauge:setFG(c) self.fg = c; self._meta = nil; self._dirty = true end

function Gauge:getBORDER() return self.border end
function Gauge:setBORDER(c) self.border = c; self._meta = nil; self._dirty = true end

--- remaps red to a proper dark red on this monitor
function Gauge:applyRecommendedPalette()
    local sc = self.screen
    if not sc or not sc.setPaletteColour then return end
    sc.setPaletteColour(colors.red,  0x3A0E0E)
    sc.setPaletteColour(colors.pink, 0xFF6B6B)
    self._dirty = true
end

return Gauge