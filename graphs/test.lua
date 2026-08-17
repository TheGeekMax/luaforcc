--[[
    demo.lua - test graph.lua in-game without any peripheral

    Put graph.lua and demo.lua on the computer, attach an advanced monitor,
    then run:  demo
]]

local Graph = require("graph")

local mon = peripheral.find("monitor")
if not mon then error("no monitor found", 0) end
mon.setTextScale(0.5)
mon.setBackgroundColour(colors.black)
mon.clear()

local W, H = mon.getSize()

local g = Graph.new(mon, 3, 2, W - 4, H - 4, 0, 100000, 0.33, 0.66)
g:setUnit("RF")
g:applyRecommendedPalette()      -- proper dark bands, comment out to keep vanilla colours

-- fake data source; replace with e.g. detector.getTransferRate()
local t = 0
local function sample()
    t = t + 1
    return 50000
         + 42000 * math.sin(t / 18)
         +  9000 * math.sin(t / 3.1)
         +  4000 * (math.random() - 0.5)
end

-- ~15 fps
local period = 1 / 15
local timer = os.startTimer(period)
local frames, t0 = 0, os.clock()

while true do
    local ev, id = os.pullEvent()
    if ev == "timer" and id == timer then
        g:addValue(sample())
        g:show()
        frames = frames + 1
        timer = os.startTimer(period)

        -- print the real framerate to the computer's own terminal
        if frames % 30 == 0 then
            local dt = os.clock() - t0
            term.setCursorPos(1, 1)
            term.clearLine()
            term.write(("%.1f fps  (%d frames)"):format(frames / dt, frames))
        end
    elseif ev == "key" or ev == "monitor_touch" then
        break
    end
end

mon.setBackgroundColour(colors.black)
mon.clear()
print("stopped")