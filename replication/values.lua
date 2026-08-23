
local aebridge = peripheral.wrap("me_bridge_2")
local Gauge = require("gauge")
local mon = peripheral.find("monitor")
local maxAmmount = 256000
local midAmmount = maxAmmount / 2
local lowAmmount = maxAmmount / 4

-- defensive check
if not mon then error("no monitor found", 0) end
mon.setTextScale(0.5)
mon.setBackgroundColour(colors.black)
mon.clear()

if not aebridge then
    print("no aebridge found", 0)
    sleep(5)
    os.reboot()
end

-- layout and data definitions


local position = {
    orx = 9,
    ory = 2,
    w = 7,
    h= 40,
    space = 1,
}


local data = {
    {
        id = "rep_ae2_bridge:earth",
        value = 0.0,
        color = "green",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:nether",
        value = 0.0,
        color = "red",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:organic",
        value = 0.0,
        color = "orange",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:ender",
        value = 0.0,
        color = "blue",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:metallic",
        value = 0.0,
        color = "gray",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:precious",
        value = 0.0,
        color = "yellow",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:living",
        value = 0.0,
        color = "pink",
        gauge = nil,
        currentlevel="l",
    },
    {
        id = "rep_ae2_bridge:quantum",
        value = 0.0,
        color = "purple",
        gauge = nil,
        currentlevel="l",
    },
}  

-- gauge creations 

for i, v in ipairs(data) do
    local g = Gauge.new(mon, position.orx + (i - 1) * (position.w + position.space), position.ory , position.w, position.h, 0, 256000)
    g:setBG(colors.black)
    g:setFG(colors[v.color])
    g:setBORDER(colors.white)
    g:setValue(v.value)
    g:show()
    data[i].gauge = g
end

-- main loop

while true do
    for i, v in ipairs(data) do
        local value = aebridge.getItem({name = v.id}).count
        data[i].gauge:setValue(value)
        data[i].gauge:show()
        local newLevel = "h"
        if value < lowAmmount then
            newLevel = "l"
        elseif value < midAmmount then
            newLevel = "m"
        end

        if newLevel ~= data[i].currentlevel then
            data[i].currentlevel = newLevel
            if newLevel == "h" then
                data[i].gauge:setBORDER(colors.white)
            elseif newLevel == "m" then
                data[i].gauge:setBORDER(colors.yellow)
            elseif newLevel == "l" then
                data[i].gauge:setBORDER(colors.red)
            end
            data[i].gauge:invalidate()
        end
    end

end