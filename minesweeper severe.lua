--!optimize 2
loadstring(game:HttpGet("https://raw.githubusercontent.com/Sploiter13/severefuncs/refs/heads/main/merge2.lua"))();
task.wait(5)

print("[Severe] Minesweeper Solver Loaded")
print("[Controls] Press X to toggle Auto-Flag")

-- Set globals after merge2 loads
if not getgenv then
    getgenv = function() return _G end
end
getgenv().MS_RUN = true
getgenv().MS_AUTOFLAG = false

-- === CONFIG === --
local CONFIG = {
    FlagName = "Flag",
    PartsName = "Parts",
    SafeText = "",
    MineColor = Color3.fromRGB(205, 142, 100),
    Spacing = 5,
    Origin = Vector3.new(0, 70, 0),
    LoopDelay = 0.01,
    NewCheckInterval = 1.0,
    
    AutoFlag = {
        MinConfidence = 0.99,
        ToggleKey = "X",
        MaxRange = 17,
        ClickDelay = 0.05,
        VerifyDelay = 0.1,
        Smoothness = 1.0,
        ClickTolerance = 45
    }
}

local NEW_CHECK_TICKS = math.max(1, math.floor(CONFIG.NewCheckInterval / CONFIG.LoopDelay))

-- === DRAWING HELPERS === --
local markers = {}  -- part -> Drawing
local statusText = nil

local function InitStatusIndicator()
    if statusText then return end
    
    local txt = Drawing.new("Text")
    txt.Text = "AUTO-FLAG: OFF (X)"
    txt.Color = Color3.fromRGB(255, 60, 60)
    txt.Outline = true
    txt.Center = false
    txt.Size = 16
    txt.Visible = true
    txt.ZIndex = 10
    txt.Position = Vector2.new(12, 805)  -- Above the Mines/Flags/Timer box
    
    statusText = txt
end

local function UpdateStatusIndicator()
    if not statusText then InitStatusIndicator() end
    
    local af = getgenv().MS_AUTOFLAG
    if af then
        statusText.Text = "AUTO-FLAG: ON (X)"
        statusText.Color = Color3.fromRGB(60, 255, 60)
    else
        statusText.Text = "AUTO-FLAG: OFF (X)"
        statusText.Color = Color3.fromRGB(255, 60, 60)
    end
end

local function NewMarker(txt, color)
    local d = Drawing.new("Text")
    d.Text = txt
    d.Color = color
    d.Outline = true
    d.Center = true
    d.Size = 22
    d.Visible = true
    d.ZIndex = 3
    return d
end

local function SetMarker(part, txt, col)
    if not part or not part.Parent then return end
    
    local m = markers[part]
    if not m then
        m = NewMarker(txt, col)
        markers[part] = m
    else
        m.Text = txt
        m.Color = col
    end
    
    local camera = workspace.CurrentCamera
    if camera then
        local screenPos, onScreen = camera:WorldToScreenPoint(part.Position)
        if onScreen then
            m.Position = Vector2.new(screenPos.X, screenPos.Y)
            m.Visible = true
        else
            m.Visible = false
        end
    end
end

local function RemoveMarker(part)
    if not part then return end
    local m = markers[part]
    if m then
        pcall(function() m:Remove() end)
        markers[part] = nil
    end
end

-- === TILE CLASSIFICATION === --
local function ClassifyTile(part)
    if not part or not part.Parent then
        return "deleted", nil
    end
    
    local numberGui = part:FindFirstChild("NumberGui")
    if numberGui then
        local label = numberGui:FindFirstChild("TextLabel")
        if label then
            local ok, text = pcall(function() return label.Text end)
            if ok and type(text) == "string" then
                if text == CONFIG.SafeText or text == "" or text == " " then
                    return "empty", 0
                end
                local n = tonumber(text)
                if n then
                    return "number", n
                end
            end
        end
    end
    
    local ok, col = pcall(function() return part.Color end)
    if ok and col == CONFIG.MineColor then
        return "mine", nil
    end
    
    return "unknown", nil
end

-- === POSITION TO GRID KEY === --
local function PosToKey(part)
    if not part or not part.Parent then return nil end
    local ok, pos = pcall(function() return part.Position end)
    if not ok or not pos then return nil end
    
    local gx = math.floor((pos.X - CONFIG.Origin.X) / CONFIG.Spacing + 0.5)
    local gz = math.floor((pos.Z - CONFIG.Origin.Z) / CONFIG.Spacing + 0.5)
    return gx.."|"..gz, gx, gz
end

-- === TILE STORAGE === --
local tiles = {}
local grid = {}

local function GenerateTile(part)
    if not part or not part.Parent then return end
    local key, gx, gz = PosToKey(part)
    if not key then return end
    
    if grid[key] then
        if grid[key].part == part then return end
        RemoveMarker(grid[key].part)
    end
    
    local tp, val = ClassifyTile(part)
    local t = {
        part = part,
        gx = gx,
        gz = gz,
        type = tp,
        number = val,
        predicted = false,
        flagged = false
    }
    tiles[#tiles+1] = t
    grid[key] = t
end

-- === NEIGHBOR OFFSETS === --
local NEIGHBOR_OFFSETS = {
    {-1,-1}, {-1,0}, {-1,1},
    {0,-1},          {0,1},
    {1,-1},  {1,0},  {1,1}
}

local function GetNeighbors(t)
    local out = {}
    for _, o in ipairs(NEIGHBOR_OFFSETS) do
        local key = (t.gx + o[1]).."|"..(t.gz + o[2])
        local v = grid[key]
        if v then out[#out+1] = v end
    end
    return out
end

-- === SOLVER === --
local function AnalyzeNeighbors(t)
    local adj = GetNeighbors(t)
    local knownMines = 0
    local unknowns = {}
    
    for _, n in ipairs(adj) do
        if n.type == "mine" then
            knownMines = knownMines + 1
        elseif n.predicted == "mine" then
            knownMines = knownMines + 1
        elseif n.predicted == "safe" then
            -- Skip
        elseif n.type == "unknown" then
            table.insert(unknowns, n)
        end
    end
    
    return knownMines, unknowns
end

local function RunTrivialPass()
    local progress = false
    
    for _, tile in ipairs(tiles) do
        if tile.type == "number" and tile.number then
            local knownMines, unknowns = AnalyzeNeighbors(tile)
            local need = tile.number - knownMines
            
            if #unknowns > 0 and need >= 0 then
                if need == 0 then
                    for _, u in ipairs(unknowns) do
                        if u.predicted ~= "safe" then
                            u.predicted = "safe"
                            progress = true
                        end
                    end
                elseif need == #unknowns then
                    for _, u in ipairs(unknowns) do
                        if u.predicted ~= "mine" then
                            u.predicted = "mine"
                            progress = true
                        end
                    end
                end
            end
        end
    end
    
    return progress
end

local function CalculateProbabilities()
    local density = 0.207
    
    for _, tile in ipairs(tiles) do
        if tile.type == "unknown" and not tile.predicted then
            local neighbors = GetNeighbors(tile)
            local totalProb = 0
            local count = 0
            
            for _, n in ipairs(neighbors) do
                if n.type == "number" and n.number then
                    local knownMines, unknowns = AnalyzeNeighbors(n)
                    if #unknowns > 0 then
                        local need = n.number - knownMines
                        if need >= 0 then
                            local prob = need / #unknowns
                            totalProb = totalProb + prob
                            count = count + 1
                        end
                    end
                end
            end
            
            if count > 0 then
                tile.probability = totalProb / count
                tile.confidence = math.min(count / 3, 1.0)
            else
                tile.probability = density
                tile.confidence = 0.1
            end
        end
    end
end

local function SolveAll()
    -- Reset predictions
    for _, tile in ipairs(tiles) do
        if tile.type == "unknown" then
            tile.predicted = false
            tile.probability = nil
            tile.confidence = 0
        end
    end
    
    -- Run trivial solver until no progress
    for i = 1, 20 do
        if not RunTrivialPass() then
            break
        end
    end
    
    -- Calculate probabilities
    CalculateProbabilities()
end

-- === AUTO-FLAG === --
local AutoFlag = {
    PendingVerifications = {},
    LastClickTime = 0,
    LockedTarget = nil
}

local function IsAlreadyFlagged(part)
    if not part or not part.Parent then return false end
    
    if part:FindFirstChild("Flag") then return true end
    
    local transparency = part.Transparency
    if transparency and transparency > 0.9 then return true end
    
    for _, child in ipairs(part:GetChildren()) do
        local name = child.Name
        if name and type(name) == "string" then
            local nameLower = string.lower(name)
            if string.find(nameLower, "flag") or string.find(nameLower, "marker") then
                return true
            end
        end
    end
    
    return false
end

function AutoFlag.VerifyPendingFlags()
    local currentTime = tick()
    
    for i = #AutoFlag.PendingVerifications, 1, -1 do
        local entry = AutoFlag.PendingVerifications[i]
        
        if currentTime - entry.time >= CONFIG.AutoFlag.VerifyDelay then
            local tile = entry.tile
            
            if tile.part and tile.part.Parent then
                if IsAlreadyFlagged(tile.part) or tile.type == "mine" then
                    tile.flagged = true
                    
                    if AutoFlag.LockedTarget and AutoFlag.LockedTarget.tile == tile then
                        AutoFlag.LockedTarget = nil
                    end
                else
                    tile.flagged = false
                end
            end
            
            table.remove(AutoFlag.PendingVerifications, i)
        end
    end
end

function AutoFlag.GetNearbyMines()
    local candidates = {}
    
    local Players = game:GetService("Players")
    local lp = Players.LocalPlayer
    if not lp or not lp.Character then return candidates end
    
    local hrp = lp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return candidates end
    
    local charPos = hrp.Position
    
    for _, tile in ipairs(tiles) do
        if tile.predicted == "mine" and 
           not tile.flagged and
           tile.type ~= "mine" then
            
            if tile.part and tile.part.Parent then
                if not IsAlreadyFlagged(tile.part) then
                    local dx = tile.part.Position.X - charPos.X
                    local dy = tile.part.Position.Y - charPos.Y
                    local dz = tile.part.Position.Z - charPos.Z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    
                    if dist <= CONFIG.AutoFlag.MaxRange then
                        table.insert(candidates, {
                            tile = tile,
                            distance = dist,
                            position = tile.part.Position
                        })
                    end
                end
            end
        end
    end
    
    table.sort(candidates, function(a, b) return a.distance < b.distance end)
    
    return candidates
end

function AutoFlag.ProcessFlags()
    if not getgenv().MS_AUTOFLAG then 
        AutoFlag.LockedTarget = nil
        return 
    end
    
    AutoFlag.VerifyPendingFlags()
    
    local currentTime = tick()
    
    if AutoFlag.LockedTarget then
        local tile = AutoFlag.LockedTarget.tile
        
        if not tile.part or not tile.part.Parent or tile.flagged or 
           IsAlreadyFlagged(tile.part) or tile.type ~= "unknown" then
            AutoFlag.LockedTarget = nil
        end
    end
    
    if not AutoFlag.LockedTarget then
        local nearbyMines = AutoFlag.GetNearbyMines()
        
        if #nearbyMines > 0 then
            AutoFlag.LockedTarget = nearbyMines[1]
        end
    end
    
    if AutoFlag.LockedTarget then
        local camera = workspace.CurrentCamera
        if not camera then return end
        
        local screenPos, onScreen = camera:WorldToScreenPoint(AutoFlag.LockedTarget.position)
        
        if onScreen then
            local currentMouse = getmouseposition()
            
            local lerpedX = currentMouse.x + (screenPos.X - currentMouse.x) * CONFIG.AutoFlag.Smoothness
            local lerpedY = currentMouse.y + (screenPos.Y - currentMouse.y) * CONFIG.AutoFlag.Smoothness
            
            mousemoveabs(lerpedX, lerpedY)
            
            local dx = currentMouse.x - screenPos.X
            local dy = currentMouse.y - screenPos.Y
            local distToTarget = math.sqrt(dx*dx + dy*dy)
            
            if distToTarget <= CONFIG.AutoFlag.ClickTolerance and 
               currentTime - AutoFlag.LastClickTime >= CONFIG.AutoFlag.ClickDelay then
                
                local tileType = ClassifyTile(AutoFlag.LockedTarget.tile.part)
                if tileType == "unknown" then
                    local success = false
                    
                    local clickDetector = AutoFlag.LockedTarget.tile.part:FindFirstChildOfClass("ClickDetector")
                    if clickDetector then
                        success = pcall(function() fireclickdetector(clickDetector, 0) end)
                    end
                    
                    if not success then
                        local proximityPrompt = AutoFlag.LockedTarget.tile.part:FindFirstChildOfClass("ProximityPrompt")
                        if proximityPrompt then
                            success = pcall(function() fireproximityprompt(proximityPrompt) end)
                        end
                    end
                    
                    if not success then
                        success = pcall(function() mouse1click() end)
                    end
                    
                    if success then
                        AutoFlag.LastClickTime = currentTime
                        
                        table.insert(AutoFlag.PendingVerifications, {
                            tile = AutoFlag.LockedTarget.tile,
                            time = currentTime
                        })
                    end
                end
            end
        end
    end
end

-- === INITIAL SETUP === --
local FLAG = workspace:FindFirstChild(CONFIG.FlagName)
local MS = FLAG and FLAG:FindFirstChild(CONFIG.PartsName)

if MS then
    local ok, children = pcall(function() return MS:GetChildren() end)
    if ok and children then
        for _, part in ipairs(children) do
            GenerateTile(part)
        end
    end
end

SolveAll()

InitStatusIndicator()

for _, t in ipairs(tiles) do
    if t.predicted == "mine" and t.type ~= "mine" then
        SetMarker(t.part, "M", Color3.fromRGB(255, 40, 40))
    elseif t.predicted == "safe" and t.type == "unknown" then
        SetMarker(t.part, "S", Color3.fromRGB(50, 255, 50))
    end
end

-- === INPUT LOOP === --
task.spawn(function()
    print("[Input] Press X to toggle Auto-Flag")
    
    local wasPressed = false
    
    while getgenv().MS_RUN do
        local isPressed = false
        
        local ok, pressedKeys = pcall(function()
            return getpressedkeys()
        end)
        
        if ok and pressedKeys then
            for _, key in ipairs(pressedKeys) do
                if type(key) == "string" then
                    if key:upper() == "X" then
                        isPressed = true
                        break
                    end
                elseif type(key) == "number" then
                    if key == 0x58 or key == 88 or key == string.byte("X") then
                        isPressed = true
                        break
                    end
                end
            end
        end
        
        if isPressed and not wasPressed then
            getgenv().MS_AUTOFLAG = not getgenv().MS_AUTOFLAG
            print(string.format("[Auto-Flag] %s", getgenv().MS_AUTOFLAG and "ON" or "OFF"))
        end
        
        wasPressed = isPressed
        task.wait(0.05)
    end
end)

-- === MAIN LOOP === --
local tickCount = 0
local lastChildCount = MS and #MS:GetChildren() or 0

while getgenv().MS_RUN do
    local changed = false
    tickCount = tickCount + 1
    
    -- Periodically check for new/removed tiles
    if (tickCount % NEW_CHECK_TICKS) == 0 then
        local ok, children = pcall(function() return MS:GetChildren() end)
        if ok and children then
            local curCount = #children
            if curCount ~= lastChildCount then
                print(string.format("[Solver] Tile count changed: %d -> %d", lastChildCount, curCount))
                lastChildCount = curCount
                
                -- Add new tiles
                for _, part in ipairs(children) do
                    local key = PosToKey(part)
                    if key and not grid[key] then
                        GenerateTile(part)
                        changed = true
                    end
                end
                
                -- Remove deleted tiles
                for i = #tiles, 1, -1 do
                    local t = tiles[i]
                    if not t.part or not t.part.Parent then
                        RemoveMarker(t.part)
                        if t.gx and t.gz then
                            grid[t.gx.."|"..t.gz] = nil
                        end
                        table.remove(tiles, i)
                        changed = true
                    end
                end
                
                -- Full reset detected - clean everything
                if lastChildCount < 10 and curCount > 100 then
                    print("[Solver] RESET DETECTED - Cleaning all markers")
                    for part, _ in pairs(markers) do
                        RemoveMarker(part)
                    end
                    markers = {}
                    if collectgarbage then
                        collectgarbage("collect")
                    end
                end
            end
        end
    end
    
    -- Reclassify existing tiles
    for _, t in ipairs(tiles) do
        local ok, newType, newNumber = pcall(function() return ClassifyTile(t.part) end)
        if ok then
            if newType ~= t.type or newNumber ~= t.number then
                t.type = newType
                t.number = newNumber
                t.predicted = false
                RemoveMarker(t.part)
                changed = true
            end
        end
    end
    
    -- Re-solve if changed
    if changed then
        SolveAll()
    end
    
    -- Update markers
    for _, t in ipairs(tiles) do
        if t.predicted == "mine" and t.type ~= "mine" then
            local isFlagged = IsAlreadyFlagged(t.part)
            if isFlagged then
                SetMarker(t.part, "M✓", Color3.fromRGB(128, 128, 128))
            else
                SetMarker(t.part, "M", Color3.fromRGB(255, 40, 40))
            end
        elseif t.predicted == "safe" and t.type == "unknown" then
            SetMarker(t.part, "S", Color3.fromRGB(50, 255, 50))
        else
            RemoveMarker(t.part)
        end
    end
    
    -- Update marker positions
    for part, m in pairs(markers) do
        if part and part.Parent then
            local camera = workspace.CurrentCamera
            if camera then
                local screenPos, onScreen = camera:WorldToScreenPoint(part.Position)
                if onScreen then
                    m.Position = Vector2.new(screenPos.X, screenPos.Y)
                    m.Visible = true
                else
                    m.Visible = false
                end
            end
        else
            pcall(function() m:Remove() end)
            markers[part] = nil
        end
    end
    
    -- Auto-flag processing
    AutoFlag.ProcessFlags()
    
    -- Update status indicator
    UpdateStatusIndicator()
    
    task.wait(CONFIG.LoopDelay)
end

-- Cleanup on exit
for p, m in pairs(markers) do
    pcall(function() m:Remove() end)
    markers[p] = nil
end

if statusText then
    pcall(function() statusText:Remove() end)
    statusText = nil
end
