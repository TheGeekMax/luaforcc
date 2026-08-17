--[[
    demo_gauge.lua - 8 animated gauges, one colour each

    Put gauge.lua and demo_gauge.lua on the computer, attach an advanced
    monitor, then run:  demo_gauge

    Palette budget (16 colours max):
      black = screen background
      white = borders
      gray  = empty part of every gauge
      + 8 distinct fill colours
]]

local Gauge = require("gauge")

local mon = peripheral.find("monitor")
if not mon then error("no monitor found", 0) end
mon.setTextScale(0.5)
mon.setBackgroundColour(colors.black)
mon.clear()

local W, H = mon.getSize()

local FILL = {
    colors.red, colors.orange, colors.yellow, colors.lime,
    colors.cyan, colors.lightBlue, colors.purple, colors.magenta,
}
local N = #FILL

-- layout: N gauges side by side, 1 cell of gap
local gap = 1
local gw  = math.floor((W - 2 - (N - 1) * gap) / N)
if gw < 3 then gw = 3 end
local gh    = H - 2
local total = N * gw + (N - 1) * gap
local x0    = math.floor((W - total) / 2) + 1

local gauges = {}
for i = 1, N do
    local g = Gauge.new(mon, x0 + (i - 1) * (gw + gap), 2, gw, gh, 0, 100)
    g:setBG(colors.gray)
    g:setFG(FILL[i])
    g:setBORDER(colors.white)
    g:setValue(50)
    g:show()
    gauges[i] = g
end

-- each gauge gets its own period and phase
local period = 1 / 15
local timer  = os.startTimer(period)
local t      = 0
local frames, t0 = 0, os.clock()

while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == timer then
        t = t + 1
        for i = 1, N do
            local speed = 1 / (7 + i * 2.5)
            local v = 50 + 48 * math.sin(t * speed + i * 0.8)
                         +  6 * math.sin(t * speed * 3.7)
            gauges[i]:setValue(v)
            gauges[i]:show()
        end
        frames = frames + 1
        timer = os.startTimer(period)

        if frames % 30 == 0 then
            term.setCursorPos(1, 1)
            term.clearLine()
            term.write(("%.1f fps  (%d frames)"):format(frames / (os.clock() - t0), frames))
        end
    elseif ev == "key" or ev == "monitor_touch" then
        break
    end
end

mon.setBackgroundColour(colors.black)
mon.clear()
print("stopped")