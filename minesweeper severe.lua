--!optimize 2
loadstring(game:HttpGet("https://raw.githubusercontent.com/Sploiter13/severefuncs/refs/heads/main/merge2.lua"))();
task.wait(5)

print("[Severe] Minesweeper Solver Loaded")
print("[Controls] Press X to toggle Auto-Flag")

local CONFIG = {
    FlagName = "Flag",
    PartsName = "Parts",
    
    Colors = {
        Mine = Color3.fromRGB(205, 142, 100),
        PredictedMine = Color3.fromRGB(255, 60, 60),
        PredictedSafe = Color3.fromRGB(60, 255, 60)
    },
    
    Spacing = 5,
    Origin = Vector3.new(0, 70, 0),
    
    Delays = {
        Logic = 0.05,
        Render = 0.016
    },
    
    TotalMines = 99,
    MineDensity = 0.207,
    
    AutoFlag = {
        Enabled = false,
        MinConfidence = 0.95,
        ToggleKey = "X",
        MaxRange = 17
    }
}

if not getgenv then
    getgenv = function() return _G end
end
getgenv().MS_RUN = true
getgenv().MS_AUTOFLAG = false

--------------------------------------------------
-- PRECOMPUTE PROBABILITY COLORS
--------------------------------------------------

local PROB_COLOR = {}
local PROB_TEXT = {}
for pct = 0, 100 do
    local p = pct / 100
    local hue = 0.33 * (1 - p)
    PROB_COLOR[pct] = Color3.fromHSV(hue, 1, 1)
    PROB_TEXT[pct] = tostring(pct) .. "%"
end

--------------------------------------------------
-- UTILITIES
--------------------------------------------------

local Utils = {}

function Utils.SafeGet(instance, property)
    if not instance or not instance.Parent then return nil end
    local success, result = pcall(function() return instance[property] end)
    return success and result or nil
end

function Utils.SafeGetText(label)
    if not label then return nil end
    local success, result = pcall(function() return label.Text end)
    return success and result or nil
end

--------------------------------------------------
-- GRID MANAGER WITH NEIGHBOR CACHING
--------------------------------------------------

local NEIGHBOR_OFFSETS = {
    {-1,-1}, {-1,0}, {-1,1},
    {0,-1},          {0,1},
    {1,-1},  {1,0},  {1,1}
}

local GridManager = {
    Tiles = {},
    Map = {},
    NeighborCache = {}
}

function GridManager.GetGridCoordinates(position)
    if not position then return nil end
    local gridX = math.floor((position.X - CONFIG.Origin.X) / CONFIG.Spacing + 0.5)
    local gridZ = math.floor((position.Z - CONFIG.Origin.Z) / CONFIG.Spacing + 0.5)
    return gridX .. "|" .. gridZ, gridX, gridZ
end

function GridManager.AnalyzeTilePart(part)
    if not part or not part.Parent then return "deleted", nil end
    
    local numberGui = part:FindFirstChild("NumberGui")
    if numberGui then
        local label = numberGui:FindFirstChild("TextLabel")
        if label then
            local text = Utils.SafeGetText(label)
            if text then
                if text == "" or text == " " then
                    return "empty", 0
                end
                local num = tonumber(text)
                if num then
                    return "number", num
                end
            end
        end
        return "empty", 0
    end
    
    return "unknown", nil
end

function GridManager.IsAlreadyFlagged(part)
    if not part or not part.Parent then return false end
    
    local flagCheck = part:FindFirstChild("Flag")
    if flagCheck then return true end
    
    local transparency = Utils.SafeGet(part, "Transparency")
    if transparency and transparency > 0.9 then return true end
    
    local color = Utils.SafeGet(part, "Color")
    if color and color == CONFIG.Colors.Mine then return true end
    
    local children = part:GetChildren()
    for _, child in ipairs(children) do
        local name = Utils.SafeGet(child, "Name")
        if name then
            local nameLower = string.lower(name)
            if string.find(nameLower, "flag") or 
               string.find(nameLower, "marker") or
               string.find(nameLower, "mine") then
                return true
            end
        end
    end
    
    local billboard = part:FindFirstChildOfClass("BillboardGui")
    if billboard then
        local label = billboard:FindFirstChildOfClass("TextLabel")
        if label then
            local text = Utils.SafeGetText(label)
            if text and (string.find(text:lower(), "flag") or text == "🚩") then
                return true
            end
        end
    end
    
    return false
end

function GridManager.RegisterTile(part)
    local pos = Utils.SafeGet(part, "Position")
    if not pos then return end
    
    local key, gx, gz = GridManager.GetGridCoordinates(pos)
    if not key then return end
    
    local existing = GridManager.Map[key]
    if existing then
        if existing.part ~= part then
            existing.part = part
            existing.storedPos = pos
        end
        existing.gridX = gx
        existing.gridZ = gz
        
        local tileType, tileValue = GridManager.AnalyzeTilePart(part)
        if tileType ~= "deleted" then
            existing.type = tileType
            existing.number = tileValue
        end
        
        existing.predicted = false
        existing.probability = nil
        existing.flagged = GridManager.IsAlreadyFlagged(part)
        
        GridManager.NeighborCache[key] = nil
        return
    end
    
    local tileType, tileValue = GridManager.AnalyzeTilePart(part)
    local tile = {
        part = part,
        storedPos = pos,
        gridX = gx,
        gridZ = gz,
        type = tileType,
        number = tileValue,
        predicted = false,
        probability = nil,
        confidence = 0,
        flagged = GridManager.IsAlreadyFlagged(part)
    }
    
    table.insert(GridManager.Tiles, tile)
    GridManager.Map[key] = tile
    GridManager.NeighborCache[key] = nil
end

function GridManager.GetNeighbors(tile)
    local key = tile.gridX .. "|" .. tile.gridZ
    
    if GridManager.NeighborCache[key] then
        return GridManager.NeighborCache[key]
    end
    
    local neighbors = {}
    for _, offset in ipairs(NEIGHBOR_OFFSETS) do
        local nkey = (tile.gridX + offset[1]) .. "|" .. (tile.gridZ + offset[2])
        local neighbor = GridManager.Map[nkey]
        if neighbor then
            table.insert(neighbors, neighbor)
        end
    end
    
    GridManager.NeighborCache[key] = neighbors
    return neighbors
end

--------------------------------------------------
-- ADVANCED SOLVER
--------------------------------------------------

local Solver = {}

function Solver.GetState(tile)
    local neighbors = GridManager.GetNeighbors(tile)
    local unknowns = {}
    local foundMines = 0
    
    for _, n in ipairs(neighbors) do
        if n.type == "mine" or (n.predicted == "mine" and n.confidence >= CONFIG.AutoFlag.MinConfidence) then
            foundMines = foundMines + 1
        elseif n.type == "unknown" and n.predicted ~= "safe" then
            table.insert(unknowns, n)
        end
    end
    
    return unknowns, foundMines
end

-- ADVANCED: Subset-based constraint propagation
function Solver.RunAdvancedPropagation()
    local progress = false
    
    for _, tile in ipairs(GridManager.Tiles) do
        if tile.type == "number" and tile.number then
            local unknowns, found = Solver.GetState(tile)
            local need = tile.number - found
            
            if #unknowns > 0 and need >= 0 then
                -- Check against all other numbered tiles for subset relationships
                for _, other in ipairs(GridManager.Tiles) do
                    if other.type == "number" and other ~= tile and other.number then
                        local otherUnknowns, otherFound = Solver.GetState(other)
                        local otherNeed = other.number - otherFound
                        
                        if #otherUnknowns > 0 and otherNeed >= 0 then
                            -- Check if tile's unknowns are a subset of other's unknowns
                            local unknownSet = {}
                            for _, u in ipairs(unknowns) do unknownSet[u] = true end
                            
                            local isSubset = true
                            for _, u in ipairs(unknowns) do
                                local foundInOther = false
                                for _, ou in ipairs(otherUnknowns) do
                                    if u == ou then foundInOther = true; break end
                                end
                                if not foundInOther then isSubset = false; break end
                            end
                            
                            if isSubset and #unknowns < #otherUnknowns then
                                -- Calculate difference
                                local diff = {}
                                for _, ou in ipairs(otherUnknowns) do
                                    if not unknownSet[ou] then
                                        table.insert(diff, ou)
                                    end
                                end
                                
                                local mineDiff = otherNeed - need
                                
                                if mineDiff == 0 and #diff > 0 then
                                    -- All difference tiles are safe
                                    for _, dt in ipairs(diff) do
                                        if dt.predicted ~= "safe" then
                                            dt.predicted = "safe"
                                            dt.probability = 0
                                            dt.confidence = 1.0
                                            progress = true
                                        end
                                    end
                                elseif mineDiff == #diff and #diff > 0 then
                                    -- All difference tiles are mines
                                    for _, dt in ipairs(diff) do
                                        if dt.predicted ~= "mine" then
                                            dt.predicted = "mine"
                                            dt.probability = 1
                                            dt.confidence = 1.0
                                            progress = true
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return progress
end

function Solver.RunTrivial()
    local progress = false
    
    for _, tile in ipairs(GridManager.Tiles) do
        if tile.type == "number" and tile.number then
            local unknowns, found = Solver.GetState(tile)
            local need = tile.number - found
            
            if #unknowns > 0 then
                if need == 0 then
                    for _, u in ipairs(unknowns) do
                        if u.predicted ~= "safe" then
                            u.predicted = "safe"
                            u.probability = 0
                            u.confidence = 1.0
                            progress = true
                        end
                    end
                elseif need == #unknowns then
                    for _, u in ipairs(unknowns) do
                        if u.predicted ~= "mine" then
                            u.predicted = "mine"
                            u.probability = 1
                            u.confidence = 1.0
                            progress = true
                        end
                    end
                end
            end
        end
    end
    
    return progress
end

function Solver.CalculateProbabilities()
    local density = CONFIG.MineDensity
    
    for _, tile in ipairs(GridManager.Tiles) do
        if tile.type == "unknown" and not tile.predicted then
            local neighbors = GridManager.GetNeighbors(tile)
            local totalProb = 0
            local count = 0
            
            for _, n in ipairs(neighbors) do
                if n.type == "number" and n.number then
                    local unknowns, found = Solver.GetState(n)
                    if #unknowns > 0 then
                        local need = n.number - found
                        local prob = need / #unknowns
                        totalProb = totalProb + prob
                        count = count + 1
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

function Solver.Solve()
    -- Run trivial deductions (fast)
    for i = 1, 10 do
        if not Solver.RunTrivial() then break end
    end
    
    -- Run advanced propagation
    for i = 1, 5 do
        if not Solver.RunAdvancedPropagation() then break end
    end
    
    -- Run trivial again to catch new deductions
    Solver.RunTrivial()
    
    -- Calculate probabilities for remaining unknowns
    Solver.CalculateProbabilities()
end

--------------------------------------------------
-- AUTO-FLAG
--------------------------------------------------

local AutoFlag = {}

function AutoFlag.FlagMine(tile)
    if not tile or not tile.part or not tile.part.Parent then 
        return false 
    end
    
    if tile.flagged or GridManager.IsAlreadyFlagged(tile.part) then
        tile.flagged = true
        return true
    end
    
    local camera = workspace.CurrentCamera
    if not camera then return false end
    
    local worldPos = vector.create(tile.storedPos.X, tile.storedPos.Y, tile.storedPos.Z)
    local screenVec, onScreen = camera:WorldToScreenPoint(worldPos)
    
    if not onScreen then return false end
    
    local Players = game:GetService("Players")
    local lp = Players.LocalPlayer
    if not lp or not lp.Character then return false end
    
    local hrp = lp.Character:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end
    
    local charPos = hrp.Position
    local dx = tile.storedPos.X - charPos.X
    local dy = tile.storedPos.Y - charPos.Y
    local dz = tile.storedPos.Z - charPos.Z
    local distSq = dx*dx + dy*dy + dz*dz
    
    if distSq > CONFIG.AutoFlag.MaxRange * CONFIG.AutoFlag.MaxRange then
        return false
    end
    
    -- Try ClickDetector
    local clickDetector = tile.part:FindFirstChildOfClass("ClickDetector")
    if clickDetector then
        local ok = pcall(function()
            fireclickdetector(clickDetector, 0)
        end)
        if ok then
            task.wait(0.1)
            if GridManager.IsAlreadyFlagged(tile.part) then
                tile.flagged = true
                return true
            end
        end
    end
    
    -- Try ProximityPrompt
    local proximityPrompt = tile.part:FindFirstChildOfClass("ProximityPrompt")
    if proximityPrompt then
        local ok = pcall(function()
            fireproximityprompt(proximityPrompt)
        end)
        if ok then
            task.wait(0.1)
            if GridManager.IsAlreadyFlagged(tile.part) then
                tile.flagged = true
                return true
            end
        end
    end
    
    -- Try direct click
    if screenVec then
        local ok = pcall(function()
            local oldPos = getmouseposition()
            mousemoveabs(screenVec.x, screenVec.y)
            task.wait(0.03)
            mouse1click()
            task.wait(0.03)
            mousemoveabs(oldPos.x, oldPos.y)
        end)
        
        if ok then
            task.wait(0.1)
            if GridManager.IsAlreadyFlagged(tile.part) then
                tile.flagged = true
                return true
            end
        end
    end
    
    return false
end

function AutoFlag.ProcessFlags()
    if not getgenv().MS_AUTOFLAG then return end
    
    for _, tile in ipairs(GridManager.Tiles) do
        if tile.predicted == "mine" and 
           tile.confidence >= CONFIG.AutoFlag.MinConfidence and
           tile.type == "unknown" and
           not tile.flagged then
            AutoFlag.FlagMine(tile)
        end
    end
end

--------------------------------------------------
-- VISUALS (LOGIC SIDE - CREATES/DESTROYS)
--------------------------------------------------

local Visuals = {
    ActiveMarkers = {},
    RenderBuffer = {},
    Status = { text = nil }
}

function Visuals.CreateMarker(part, color)
    local square = Drawing.new("Square")
    square.Color = color
    square.Thickness = 2
    square.Filled = true
    square.Transparency = 0.6
    square.Visible = false
    square.ZIndex = 2
    square.Size = Vector2.new(20, 20)
    
    local text = Drawing.new("Text")
    text.Text = ""
    text.Color = Color3.new(1, 1, 1)
    text.Center = true
    text.Outline = true
    text.Size = 16
    text.Visible = false
    text.ZIndex = 3
    
    return {
        box = square,
        text = text,
        lastVisible = false,
        lastSX = nil,
        lastSY = nil
    }
end

function Visuals.RemoveMarker(part)
    local marker = Visuals.ActiveMarkers[part]
    if marker then
        pcall(function() marker.box:Remove() end)
        pcall(function() marker.text:Remove() end)
        Visuals.ActiveMarkers[part] = nil
    end
end

function Visuals.UpdateRenderBuffer()
    local newBuffer = {}
    local partsInBuffer = {}
    
    for _, tile in ipairs(GridManager.Tiles) do
        if tile.type == "unknown" then
            local item = nil
            
            if tile.predicted == "mine" and tile.confidence >= CONFIG.AutoFlag.MinConfidence then
                local marker = tile.flagged and "M✓" or ("M" .. math.floor(tile.confidence * 100))
                local col = tile.flagged and Color3.fromRGB(128, 128, 128) or CONFIG.Colors.PredictedMine
                item = { part = tile.part, pos = tile.storedPos, text = marker, color = col }
                
            elseif tile.predicted == "safe" and tile.confidence >= 0.99 then
                item = { part = tile.part, pos = tile.storedPos, text = "S", color = CONFIG.Colors.PredictedSafe }
                
            elseif tile.probability and tile.confidence > 0.3 then
                local pct = math.floor(tile.probability * 100 + 0.5)
                if pct <= 0 then pct = 1 end
                if pct >= 100 then pct = 99 end
                
                local col = PROB_COLOR[pct]
                local txt = PROB_TEXT[pct]
                item = { part = tile.part, pos = tile.storedPos, text = txt, color = col }
            end
            
            if item then
                table.insert(newBuffer, item)
                partsInBuffer[tile.part] = true
                
                -- Create marker if doesn't exist (LOGIC SIDE)
                if not Visuals.ActiveMarkers[item.part] then
                    Visuals.ActiveMarkers[item.part] = Visuals.CreateMarker(item.part, item.color)
                end
            end
        end
    end
    
    -- Remove markers for revealed tiles (LOGIC SIDE)
    for part, marker in pairs(Visuals.ActiveMarkers) do
        if not partsInBuffer[part] then
            Visuals.RemoveMarker(part)
        end
    end
    
    Visuals.RenderBuffer = newBuffer
end

function Visuals.InitStatusIndicator()
    if Visuals.Status.text then return end
    
    local txt = Drawing.new("Text")
    txt.Center = false
    txt.Outline = true
    txt.Size = 16
    txt.Visible = true
    txt.ZIndex = 20
    txt.Position = Vector2.new(12, 12)
    txt.Text = ""
    txt.Color = Color3.fromRGB(255, 255, 255)
    
    Visuals.Status.text = txt
    Visuals.Status._lastText = nil
end

--------------------------------------------------
-- RENDER LOOP (ONLY DRAWS - NO CREATION/LOGIC)
--------------------------------------------------

local function RenderLoop()
    Visuals.InitStatusIndicator()
    
    while getgenv().MS_RUN do
        local camera = workspace.CurrentCamera
        if camera then
            local camPos = camera.CFrame.Position
            
            -- Update status text
            if Visuals.Status.text then
                local af = getgenv().MS_AUTOFLAG
                local newText = af and "AUTO-FLAG: ON (X)" or "AUTO-FLAG: OFF (X)"
                if newText ~= Visuals.Status._lastText then
                    Visuals.Status.text.Text = newText
                    Visuals.Status.text.Color = af and Color3.fromRGB(60, 255, 60) or Color3.fromRGB(255, 60, 60)
                    Visuals.Status._lastText = newText
                end
            end
            
            -- Render markers (ONLY DRAWING - NO CREATION)
            for i = 1, #Visuals.RenderBuffer do
                local item = Visuals.RenderBuffer[i]
                local pos = item.pos
                
                if pos and item.part and item.part.Parent then
                    local marker = Visuals.ActiveMarkers[item.part]
                    
                    if marker then  -- Marker must already exist
                        local dx = pos.X - camPos.X
                        local dy = pos.Y - camPos.Y
                        local dz = pos.Z - camPos.Z
                        local distSq = dx*dx + dy*dy + dz*dz
                        
                        if distSq < 1000000 then
                            local worldPos = vector.create(pos.X, pos.Y, pos.Z)
                            local screenVec, onScreen = camera:WorldToScreenPoint(worldPos)
                            
                            if onScreen and screenVec then
                                local sx = screenVec.x
                                local sy = screenVec.y
                                
                                if sx ~= marker.lastSX or sy ~= marker.lastSY or not marker.lastVisible then
                                    local dist = math.sqrt(distSq)
                                    if dist < 1 then dist = 1 end
                                    local size = math.min(math.max(800 / dist, 10), 100)
                                    
                                    marker.box.Visible = true
                                    marker.box.Size = Vector2.new(size, size)
                                    marker.box.Position = Vector2.new(sx - size/2, sy - size/2)
                                    marker.box.Color = item.color
                                    
                                    marker.text.Visible = true
                                    marker.text.Position = Vector2.new(sx, sy - 8)
                                    marker.text.Text = item.text
                                    
                                    marker.lastVisible = true
                                    marker.lastSX = sx
                                    marker.lastSY = sy
                                end
                            elseif marker.lastVisible then
                                marker.box.Visible = false
                                marker.text.Visible = false
                                marker.lastVisible = false
                            end
                        elseif marker.lastVisible then
                            marker.box.Visible = false
                            marker.text.Visible = false
                            marker.lastVisible = false
                        end
                    end
                end
            end
        end
        
        task.wait(CONFIG.Delays.Render)
    end
end

--------------------------------------------------
-- LOGIC LOOP (ALL CREATION/DESTRUCTION HERE)
--------------------------------------------------

local function LogicLoop()
    local scanInterval = 0
    local lastPartCount = 0
    local scanCycle = 0
    local lastAutoFlagTime = 0
    
    while getgenv().MS_RUN do
        local ws = game:GetService("Workspace")
        local flag = ws:FindFirstChild(CONFIG.FlagName)
        local msParts = flag and flag:FindFirstChild(CONFIG.PartsName)
        
        if msParts then
            local gridChanged = false
            scanInterval = scanInterval + 1
            scanCycle = scanCycle + 1
            if scanCycle > 10 then scanCycle = 1 end
            
            if scanInterval >= 5 then
                scanInterval = 0
                local allParts = msParts:GetChildren()
                
                if #allParts ~= lastPartCount then
                    lastPartCount = #allParts
                    
                    local currentLookup = {}
                    for _, part in ipairs(allParts) do
                        if part.Name == "Part" then
                            currentLookup[part] = true
                            GridManager.RegisterTile(part)
                        end
                    end
                    
                    for i = #GridManager.Tiles, 1, -1 do
                        local tile = GridManager.Tiles[i]
                        if not tile.part or not tile.part.Parent or not currentLookup[tile.part] then
                            local key = tile.gridX .. "|" .. tile.gridZ
                            GridManager.Map[key] = nil
                            GridManager.NeighborCache[key] = nil
                            Visuals.RemoveMarker(tile.part)
                            table.remove(GridManager.Tiles, i)
                            gridChanged = true
                        end
                    end
                    
                    gridChanged = true
                end
            end
            
            for _, tile in ipairs(GridManager.Tiles) do
                local shouldAnalyze = (tile.type == "unknown") or (scanCycle == 1)
                if shouldAnalyze then
                    local newType, newNum = GridManager.AnalyzeTilePart(tile.part)
                    if newType ~= "deleted" and (newType ~= tile.type or newNum ~= tile.number) then
                        tile.type = newType
                        tile.number = newNum
                        tile.predicted = false
                        tile.probability = nil
                        tile.confidence = 0
                        gridChanged = true
                        
                        local key = tile.gridX .. "|" .. tile.gridZ
                        GridManager.NeighborCache[key] = nil
                        for _, offset in ipairs(NEIGHBOR_OFFSETS) do
                            local nkey = (tile.gridX + offset[1]) .. "|" .. (tile.gridZ + offset[2])
                            GridManager.NeighborCache[nkey] = nil
                        end
                    end
                    
                    tile.flagged = GridManager.IsAlreadyFlagged(tile.part)
                end
            end
            
            if gridChanged then
                Solver.Solve()
            end
            
            local currentTime = tick()
            if currentTime - lastAutoFlagTime >= 0.5 then
                lastAutoFlagTime = currentTime
                AutoFlag.ProcessFlags()
            end
            
            Visuals.UpdateRenderBuffer()
        end
        
        task.wait(CONFIG.Delays.Logic)
    end
end

--------------------------------------------------
-- INPUT LOOP
--------------------------------------------------

local function InputLoop()
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
end

--------------------------------------------------
-- START
--------------------------------------------------

task.spawn(LogicLoop)
task.spawn(RenderLoop)
task.spawn(InputLoop)
