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

-- === PRECOMPUTE PROBABILITY COLORS === --
local PROB_COLOR = {}
local PROB_TEXT = {}
for pct = 0, 100 do
    local p = pct / 100
    local hue = 0.33 * (1 - p)  -- Green (0.33) to Red (0)
    
    -- Convert HSV to RGB
    local r, g, b = 0, 0, 0
    local h = hue * 6
    local c = 1
    local x = 1 - math.abs(h % 2 - 1)
    
    if h < 1 then r, g, b = c, x, 0
    elseif h < 2 then r, g, b = x, c, 0
    elseif h < 3 then r, g, b = 0, c, x
    elseif h < 4 then r, g, b = 0, x, c
    elseif h < 5 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    
    PROB_COLOR[pct] = Color3.fromRGB(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
    PROB_TEXT[pct] = tostring(pct) .. "%"
end

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

-- === SOLVER (MATCHA-LEVEL) === --

-- Object Pools for performance
local Q_POOL, INQ_POOL = {}, {}

local function ClearArray(t)
    for i = #t, 1, -1 do t[i] = nil end
end

local function ClearMap(t)
    for k in pairs(t) do t[k] = nil end
end

local function AcquireQueues()
    local q = Q_POOL[#Q_POOL]; Q_POOL[#Q_POOL] = nil
    local inq = INQ_POOL[#INQ_POOL]; INQ_POOL[#INQ_POOL] = nil
    if not q then q = {} end
    if not inq then inq = {} end
    return q, inq
end

local function ReleaseQueues(q, inq)
    ClearArray(q)
    ClearMap(inq)
    Q_POOL[#Q_POOL + 1] = q
    INQ_POOL[#INQ_POOL + 1] = inq
end

-- Helper functions for constraint solving
local function SortAndUniq(vars)
    table.sort(vars)
    local out = {}
    local last = nil
    for i = 1, #vars do
        local v = vars[i]
        if v ~= last then out[#out + 1] = v; last = v end
    end
    return out
end

local function JoinNums(arr)
    local out = {}
    for i = 1, #arr do out[i] = tostring(arr[i]) end
    return table.concat(out, ",")
end

local function EqKey(eq) 
    return tostring(eq.needed) .. ":" .. JoinNums(eq.vars) 
end

local function IsSubset(smaller, bigger)
    local i, j = 1, 1
    while i <= #smaller and j <= #bigger do
        local a, b = smaller[i], bigger[j]
        if a == b then i=i+1; j=j+1 
        elseif a > b then j=j+1 
        else return false end
    end
    return i > #smaller
end

local function DiffVars(bigger, smaller)
    local out = {}
    local i, j = 1, 1
    while i <= #bigger do
        local b = bigger[i]
        local s = smaller[j]
        if s == nil then 
            out[#out+1]=b; i=i+1 
        elseif b==s then 
            i=i+1; j=j+1 
        elseif b<s then 
            out[#out+1]=b; i=i+1 
        else 
            j=j+1 
        end
    end
    return out
end

-- Constraint reduction (derives new constraints from existing ones)
local function ReduceEquations(localEqs)
    local normalized = {}
    local byVarSet = {}
    
    for _, eq in ipairs(localEqs) do
        local vars = SortAndUniq(eq.vars)
        local needed = eq.needed
        if needed < 0 or needed > #vars then return nil, "contradiction" end
        
        local varSetKey = JoinNums(vars)
        local existing = byVarSet[varSetKey]
        if existing == nil then
            byVarSet[varSetKey] = needed
            normalized[#normalized + 1] = { needed = needed, vars = vars }
        else
            if existing ~= needed then return nil, "contradiction" end
        end
    end
    
    local seen = {}
    for _, eq in ipairs(normalized) do seen[EqKey(eq)] = true end
    
    local HARD_EQ_CAP = 256
    local changed = true
    
    while changed do
        changed = false
        for i = 1, #normalized do
            local A = normalized[i]
            for j = 1, #normalized do
                if i ~= j then
                    local B = normalized[j]
                    if #A.vars > 0 and #A.vars < #B.vars then
                        if IsSubset(A.vars, B.vars) then
                            local diffNeeded = B.needed - A.needed
                            local diffVars = DiffVars(B.vars, A.vars)
                            if diffNeeded < 0 or diffNeeded > #diffVars then 
                                return nil, "contradiction" 
                            end
                            if #diffVars == 0 then
                                if diffNeeded ~= 0 then return nil, "contradiction" end
                            else
                                local newEq = { needed = diffNeeded, vars = diffVars }
                                local k = EqKey(newEq)
                                if not seen[k] then
                                    seen[k] = true
                                    normalized[#normalized + 1] = newEq
                                    changed = true
                                    if #normalized > HARD_EQ_CAP then 
                                        return normalized, "cap_hit" 
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    return normalized, "ok"
end

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

-- MATCHA's advanced Tank solver with constraint propagation
local function RunTankSolver()
    local madeProgress = false
    
    -- Build constraint system
    local unknownMap = {}
    local unknownList = {}
    local equations = {}
    
    for _, tile in ipairs(tiles) do
        if tile.type == "number" and tile.number then
            local knownMines, unknowns = AnalyzeNeighbors(tile)
            local needed = tile.number - knownMines
            
            if #unknowns > 0 and needed >= 0 then
                local eqVars = {}
                for _, uTile in ipairs(unknowns) do
                    if not unknownMap[uTile] then
                        table.insert(unknownList, uTile)
                        unknownMap[uTile] = #unknownList
                    end
                    table.insert(eqVars, unknownMap[uTile])
                end
                table.insert(equations, { needed = needed, vars = eqVars })
            end
        end
    end
    
    if #unknownList == 0 then return false end
    
    -- Build var-to-equation index
    local varToEqIndex = {}
    for i = 1, #unknownList do varToEqIndex[i] = {} end
    for eqIdx, eq in ipairs(equations) do
        for _, varId in ipairs(eq.vars) do
            table.insert(varToEqIndex[varId], eqIdx)
        end
    end
    
    -- Find independent clusters
    local visitedVars = {}
    local clusters = {}
    
    for i = 1, #unknownList do
        if not visitedVars[i] then
            local clusterVars = {}
            local clusterEqs = {}
            local queue = {i}
            visitedVars[i] = true
            local processedEqs = {}
            local head = 1
            
            while head <= #queue do
                local currVar = queue[head]
                head = head + 1
                table.insert(clusterVars, currVar)
                
                for _, eqIdx in ipairs(varToEqIndex[currVar]) do
                    if not processedEqs[eqIdx] then
                        processedEqs[eqIdx] = true
                        table.insert(clusterEqs, equations[eqIdx])
                        
                        for _, neighborVar in ipairs(equations[eqIdx].vars) do
                            if not visitedVars[neighborVar] then
                                visitedVars[neighborVar] = true
                                table.insert(queue, neighborVar)
                            end
                        end
                    end
                end
            end
            
            table.insert(clusters, { vars = clusterVars, eqs = clusterEqs })
        end
    end
    
    -- Weight table for density-based probability
    local density = 0.207
    local ratio = density / (1 - density)
    local weightTable = {}
    for k = 0, 50 do
        weightTable[k] = math.pow(ratio, k)
    end
    
    -- Solve each cluster
    for _, cluster in ipairs(clusters) do
        if #cluster.vars <= 16 then
            -- Order vars by degree (heuristic for faster solving)
            local orderedVars = {}
            for i = 1, #cluster.vars do orderedVars[i] = cluster.vars[i] end
            
            local degree = {}
            for i = 1, #orderedVars do degree[orderedVars[i]] = 0 end
            for _, eq in ipairs(cluster.eqs) do
                for _, globId in ipairs(eq.vars) do
                    if degree[globId] ~= nil then 
                        degree[globId] = degree[globId] + 1 
                    end
                end
            end
            
            table.sort(orderedVars, function(a, b) 
                return (degree[a] or 0) > (degree[b] or 0) 
            end)
            
            local globalToLocal = {}
            local localToGlobal = {}
            for locIdx, globId in ipairs(orderedVars) do
                globalToLocal[globId] = locIdx
                localToGlobal[locIdx] = globId
            end
            
            local nVars = #orderedVars
            local localEqs = {}
            for _, eq in ipairs(cluster.eqs) do
                local vars = {}
                for _, globId in ipairs(eq.vars) do 
                    vars[#vars + 1] = globalToLocal[globId] 
                end
                localEqs[#localEqs + 1] = { needed = eq.needed, vars = vars }
            end
            
            -- Reduce equations (derive new constraints)
            local reduceStatus
            localEqs, reduceStatus = ReduceEquations(localEqs)
            
            if localEqs then
                local varToEqs = {}
                for v = 1, nVars do varToEqs[v] = {} end
                for eqIdx, eq in ipairs(localEqs) do
                    for _, v in ipairs(eq.vars) do 
                        varToEqs[v][#varToEqs[v] + 1] = eqIdx 
                    end
                end
                
                local varDegree = {}
                for v = 1, nVars do varDegree[v] = #varToEqs[v] end
                
                local assignment = {}
                local eqMines = {}
                local eqUnk = {}
                for eqIdx, eq in ipairs(localEqs) do
                    eqMines[eqIdx] = 0
                    eqUnk[eqIdx] = #eq.vars
                end
                
                -- Track solutions
                local solutionHits = {}
                for v=1, nVars do solutionHits[v] = {} end
                local totalWeightLocal = 0
                
                local function EnqueueEq(q, inQueue, eqIdx)
                    if not inQueue[eqIdx] then 
                        inQueue[eqIdx] = true
                        q[#q + 1] = eqIdx 
                    end
                end
                
                local function AssignVar(v, val, trail, q, inQueue)
                    if assignment[v] ~= nil then 
                        return assignment[v] == val 
                    end
                    assignment[v] = val
                    trail[#trail + 1] = { v = v, val = val }
                    for _, eqIdx in ipairs(varToEqs[v]) do
                        eqUnk[eqIdx] = eqUnk[eqIdx] - 1
                        eqMines[eqIdx] = eqMines[eqIdx] + val
                        EnqueueEq(q, inQueue, eqIdx)
                    end
                    return true
                end
                
                local function UndoTo(trail, targetSize)
                    while #trail > targetSize do
                        local rec = trail[#trail]
                        trail[#trail] = nil
                        local v, val = rec.v, rec.val
                        assignment[v] = nil
                        for _, eqIdx in ipairs(varToEqs[v]) do
                            eqUnk[eqIdx] = eqUnk[eqIdx] + 1
                            eqMines[eqIdx] = eqMines[eqIdx] - val
                        end
                    end
                end
                
                local function Propagate(trail, q, inQueue)
                    local head = 1
                    while head <= #q do
                        local eqIdx = q[head]
                        head = head + 1
                        inQueue[eqIdx] = false
                        local eq = localEqs[eqIdx]
                        local need = eq.needed
                        local mines = eqMines[eqIdx]
                        local unk = eqUnk[eqIdx]
                        
                        if mines > need then return false end
                        if mines + unk < need then return false end
                        
                        if unk > 0 then
                            if mines == need then
                                for _, v in ipairs(eq.vars) do
                                    if assignment[v] == nil then 
                                        if not AssignVar(v, 0, trail, q, inQueue) then 
                                            return false 
                                        end 
                                    end
                                end
                            elseif mines + unk == need then
                                for _, v in ipairs(eq.vars) do
                                    if assignment[v] == nil then 
                                        if not AssignVar(v, 1, trail, q, inQueue) then 
                                            return false 
                                        end 
                                    end
                                end
                            end
                        else
                            if mines ~= need then return false end
                        end
                    end
                    return true
                end
                
                local function PickNextVar()
                    local bestV, bestScore = nil, -1
                    for v = 1, nVars do
                        if assignment[v] == nil then
                            local score = varDegree[v]
                            if score > bestScore then 
                                bestScore = score
                                bestV = v 
                            end
                        end
                    end
                    return bestV
                end
                
                local function Backtrack(trail)
                    local v = PickNextVar()
                    if not v then
                        -- Found a solution
                        local m = 0
                        for i = 1, nVars do 
                            if assignment[i] == 1 then m = m + 1 end 
                        end
                        
                        -- Weight by mine density
                        local w = weightTable[m] or 1
                        totalWeightLocal = totalWeightLocal + w
                        
                        for i = 1, nVars do
                            if assignment[i] == 1 then
                                solutionHits[i][m] = (solutionHits[i][m] or 0) + 1
                            end
                        end
                        return
                    end
                    
                    do
                        local saved = #trail
                        local q, inQueue = AcquireQueues()
                        if AssignVar(v, 0, trail, q, inQueue) and 
                           Propagate(trail, q, inQueue) then 
                            Backtrack(trail) 
                        end
                        ReleaseQueues(q, inQueue)
                        UndoTo(trail, saved)
                    end
                    
                    do
                        local saved = #trail
                        local q, inQueue = AcquireQueues()
                        if AssignVar(v, 1, trail, q, inQueue) and 
                           Propagate(trail, q, inQueue) then 
                            Backtrack(trail) 
                        end
                        ReleaseQueues(q, inQueue)
                        UndoTo(trail, saved)
                    end
                end
                
                -- Run backtracking solver
                local trail, q, inQueue = {}, {}, {}
                for eqIdx = 1, #localEqs do EnqueueEq(q, inQueue, eqIdx) end
                if Propagate(trail, q, inQueue) then Backtrack(trail) end
                
                -- Calculate weighted probabilities
                if totalWeightLocal > 0 then
                    for locIdx, globId in ipairs(orderedVars) do
                        local tile = unknownList[globId]
                        
                        local weightedHits = 0
                        local hitsMap = solutionHits[locIdx]
                        
                        for m, count in pairs(hitsMap) do
                            local w = weightTable[m] or 1
                            weightedHits = weightedHits + (count * w)
                        end
                        
                        local prob = weightedHits / totalWeightLocal
                        
                        if prob < 0 then prob = 0 end
                        if prob > 1 then prob = 1 end
                        
                        tile.probability = prob
                        
                        if prob < 1e-6 and tile.predicted ~= "safe" then
                            tile.predicted = "safe"
                            madeProgress = true
                        elseif prob > 1 - 1e-6 and tile.predicted ~= "mine" then
                            tile.predicted = "mine"
                            madeProgress = true
                        end
                    end
                end
            end
        end
    end
    
    return madeProgress
end

local function SolveAll()
    -- Reset predictions
    for _, tile in ipairs(tiles) do
        if tile.type == "unknown" then
            tile.predicted = false
            tile.probability = nil
        end
    end
    
    -- Run trivial solver multiple times
    for i = 1, 10 do
        if not RunTrivialPass() then
            break
        end
    end
    
    -- Run advanced constraint solver
    if RunTankSolver() then
        -- One more trivial pass after Tank
        RunTrivialPass()
    end
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
                changed = true
            end
        end
    end
    
    -- ALWAYS re-solve (not just when changed)
    -- This ensures predictions are always current
    if changed then
        -- Full solve when grid changes
        SolveAll()
    end
    
    -- ALWAYS update markers every loop (not just when changed)
    -- Use CHANGE DETECTION - only update if marker state changed
    local updatesThisFrame = 0
    local maxUpdates = 20  -- Even more conservative
    
    for _, t in ipairs(tiles) do
        if updatesThisFrame >= maxUpdates then
            break
        end
        
        -- Calculate what the marker SHOULD be
        local shouldShow = false
        local markerText = nil
        local markerColor = nil
        
        if t.type == "unknown" then
            if t.predicted == "mine" then
                -- Check if flagged (but don't check every frame - use tile cache)
                if not t._lastFlagCheck or (tick() - t._lastFlagCheck) > 0.5 then
                    t._isFlagged = IsAlreadyFlagged(t.part)
                    t._lastFlagCheck = tick()
                end
                
                if not t._isFlagged then
                    shouldShow = true
                    markerText = "M"
                    markerColor = Color3.fromRGB(255, 40, 40)
                end
            elseif t.predicted == "safe" then
                if not t._lastFlagCheck or (tick() - t._lastFlagCheck) > 0.5 then
                    t._isFlagged = IsAlreadyFlagged(t.part)
                    t._lastFlagCheck = tick()
                end
                
                shouldShow = true
                if t._isFlagged then
                    markerText = "S!"
                    markerColor = Color3.fromRGB(255, 165, 0)
                else
                    markerText = "S"
                    markerColor = Color3.fromRGB(50, 255, 50)
                end
            elseif t.probability and t.probability > 0.01 and t.probability < 0.99 then
                -- Cache neighbor check
                if t._hasRevealedNeighbor == nil then
                    t._hasRevealedNeighbor = false
                    local neighbors = GetNeighbors(t)
                    for _, n in ipairs(neighbors) do
                        if n.type == "number" or n.type == "empty" then
                            t._hasRevealedNeighbor = true
                            break
                        end
                    end
                end
                
                if t._hasRevealedNeighbor then
                    if not t._lastFlagCheck or (tick() - t._lastFlagCheck) > 0.5 then
                        t._isFlagged = IsAlreadyFlagged(t.part)
                        t._lastFlagCheck = tick()
                    end
                    
                    if not t._isFlagged then
                        shouldShow = true
                        local pct = math.floor(t.probability * 100 + 0.5)
                        if pct <= 0 then pct = 1 end
                        if pct >= 100 then pct = 99 end
                        markerText = PROB_TEXT[pct]
                        markerColor = PROB_COLOR[pct]
                    end
                end
            end
        end
        
        -- Build state key for change detection
        local stateKey = shouldShow and (markerText .. "|" .. tostring(markerColor)) or "NONE"
        
        -- Only update if state changed
        if t._lastMarkerState ~= stateKey then
            if shouldShow then
                SetMarker(t.part, markerText, markerColor)
            else
                RemoveMarker(t.part)
            end
            t._lastMarkerState = stateKey
            updatesThisFrame = updatesThisFrame + 1
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
