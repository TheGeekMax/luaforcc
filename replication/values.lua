
local aebridge = peripheral.wrap("me_bridge_1")
local Gauge = require("gauge")
local mon = peripheral.find("monitor")

-- defensive check
if not mon then error("no monitor found", 0) end
mon.setTextScale(0.5)
mon.setBackgroundColour(colors.black)
mon.clear()

if not aebridge then error("no aebridge found", 0) end

-- layout and data definitions


local position = {
    orx = 2,
    ory = 2,
    w = 7,
    h= 22,
    space = 1,
}


local data = {
    {
        id = "rep_ae2_bridge:earth",
        value = 0.0,
        color = "green",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:nether",
        value = 0.0,
        color = "red",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:organic",
        value = 0.0,
        color = "orange",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:ender",
        value = 0.0,
        color = "blue",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:metallic",
        value = 0.0,
        color = "gray",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:precious",
        value = 0.0,
        color = "yellow",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:living",
        value = 0.0,
        color = "pink",
        gauge = nil,
    },
    {
        id = "rep_ae2_bridge:quantum",
        value = 0.0,
        color = "purple",
        gauge = nil,
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
    end

end