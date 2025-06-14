local debug = false
local lastDebugMessage = ""

local IN = 0
local OUT = 1
local BOTH = 2

local targetVolume = { name = "Target Volume", mode = IN, value = 0, prevValue = 0, min = 0, max = 100000, rangeStart = 0, rangeEnd = 0, precision = 1 }
local chaffEmitter = { name = "Chaff Emitter", mode = OUT, value = 0, prevValue = -1, min = 0, max = 10, rangeStart = 0, rangeEnd = 0, precision = 1 }
local jetGenerator = { name = "Jet Generator", mode = OUT, value = 0, prevValue = -1, min = 0, max = 100, rangeStart = 0, rangeEnd = 0, precision = 1 }
local exampleBool = { name = "Example Bool", mode = OUT, value = 0, prevValue = -1, min = 0, max = 1, rangeStart = 0, rangeEnd = 0, precision = 1 }

local memoryCellArray = { targetVolume, chaffEmitter, jetGenerator, exampleBool }
local memoryCellOccupancy = 0
local memoryCellMultiplier = 10 ^ 7
local memoryCellTransitQueue = {}
local memoryCellInit = true

local threatTTILimitMissiles = 3;
local threatTTILimitFlare = 8

local leftFlareIndex = 4
local rightFlareIndex = 5
local leftFlareReloadTs = 0
local rightFlareReloadTs = 0
local flareSeparation = 8

local pitchStrength = 1
local yawStrength = 1
local rollStrength = 1
local predictionTime = 3

local totalThreatLevel = 0

local minAltitude = 70
local maxAltitude = 500

local friendlyAvoidanceTolerance = 300

function MemoryCellInit(I)
    for i, cell in pairs(memoryCellArray) do
        cell.rangeStart = memoryCellOccupancy
        if (memoryCellOccupancy ~= 0) then
            cell.rangeStart = cell.rangeStart + (1 / memoryCellMultiplier)
        end
        local requiredSpace = (cell.max - cell.min) / cell.precision / memoryCellMultiplier
        memoryCellOccupancy = cell.rangeStart + requiredSpace
        cell.rangeEnd = memoryCellOccupancy
        DebugLog(I, "Cell : " .. cell.name .. " Range " .. cell.rangeStart .. " To " .. cell.rangeEnd)
    end
end

function UpdateMemoryCell(I, inputDriveIndex, outputDriveIndex)
    local memoryCellValue = I:GetPropulsionRequest(inputDriveIndex)

    --I:Log(memoryCellValue)

    for i, cell in pairs(memoryCellArray) do
        if (cell.mode == IN or cell.mode == BOTH) then
            if (memoryCellValue >= cell.rangeStart and memoryCellValue < cell.rangeEnd) then
                local cellValue = (memoryCellValue - cell.rangeStart) * memoryCellMultiplier * cell.precision

                if (cell.value ~= cellValue) then
                    cell.value = cellValue
                    DebugLog(I, "Updated Cell " .. cell.name .. " : " .. cell.value)
                end
            end
        end

        if (cell.value ~= cell.prevValue and (cell.mode == OUT or cell.mode == BOTH)) then
            if (cell.value >= cell.min and cell.value <= cell.max) then
                table.insert(memoryCellTransitQueue, #memoryCellTransitQueue + 1,
                    {
                        name = cell.name,
                        value = cell.value,
                        transmitValue = cell.rangeStart +
                            cell.value / memoryCellMultiplier / cell.precision
                    })
            end
            cell.prevValue = cell.value
        end
    end

    if (#memoryCellTransitQueue > 0) then
        local msg = string.format(
            "Transmit Cell : %s | Value : %.10f | Cell Raw : %.10f",
            memoryCellTransitQueue[1].name,
            memoryCellTransitQueue[1].value,
            memoryCellTransitQueue[1].transmitValue
        )
        DebugLog(I, msg)
        I:SetPropulsionRequest(outputDriveIndex, memoryCellTransitQueue[1].transmitValue)
        table.remove(memoryCellTransitQueue, 1)
    end
end

function FireFlare(I, preferredIndex)
    local currentTime = I:GetTime()

    if currentTime - leftFlareReloadTs < flareSeparation or currentTime - rightFlareReloadTs < flareSeparation then
        --DebugLog(I, "Too soon since last flare!")
        return
    end

    local leftReady = currentTime - leftFlareReloadTs >= 25
    local rightReady = currentTime - rightFlareReloadTs >= 25

    if preferredIndex == leftFlareIndex then
        if leftReady then
            FireFlareAtIndex(I, leftFlareIndex)
        elseif rightReady then
            FireFlareAtIndex(I, rightFlareIndex)
        else
            DebugLog(I, "No flares available!")
        end
    elseif preferredIndex == rightFlareIndex then
        if rightReady then
            FireFlareAtIndex(I, rightFlareIndex)
        elseif leftReady then
            FireFlareAtIndex(I, leftFlareIndex)
        else
            DebugLog(I, "No flares available!")
        end
    end
end

function FireFlareAtIndex(I, index)
    I:AimWeaponInDirection(index, 0, 0, 1, 0)
    I:FireWeapon(index, 0)

    if index == leftFlareIndex then
        leftFlareReloadTs = I:GetTime()
    else
        rightFlareReloadTs = I:GetTime()
    end

    DebugLog(I, (string.format("Fired %s flare!", index == leftFlareIndex and "LEFT" or "RIGHT")))
end

function GetMissileSide(I, warning)
    local myPos = I:GetConstructCenterOfMass()
    local relPos = warning.Position - myPos
    local rightVec = I:GetConstructRightVector()

    local dot = Vector3.Dot(relPos.normalized, rightVec)
    return dot >= 0 and "right" or "left"
end

function MissileEvade(I, mainframeIndex)
    local count = I:GetNumberOfWarnings(mainframeIndex)
    local myPos = I:GetConstructCenterOfMass()
    local myVel = I:GetVelocityVector()

    local pitchDodge = 0
    local yawDodge = 0
    local rollDodge = 0
    local threats = 0

    local fireLeft = false
    local fireRight = false

    for i = 0, count - 1 do
        local warning = I:GetMissileWarning(mainframeIndex, i)
        if warning.Valid then
            local relPos = myPos - warning.Position
            local relVel = warning.Velocity - myVel
            local distance = relPos.magnitude
            local closingSpeed = Vector3.Dot(relVel.normalized, relPos.normalized) * relVel.magnitude

            if closingSpeed > 0 then
                local tti = distance / closingSpeed

                totalThreatLevel = (10 - tti) * 100

                if tti < threatTTILimitMissiles then
                    threats = threats + 1

                    local forward = relVel.normalized
                    local right = Vector3.Cross(forward, Vector3.up).normalized
                    local up = Vector3.Cross(right, forward).normalized
                    local rollVec = Vector3.Cross(forward, up).normalized

                    local strength = (1 / tti)

                    yawDodge = yawDodge + right.x * strength * yawStrength
                    pitchDodge = pitchDodge + up.y * strength * pitchStrength
                    rollDodge = rollDodge + rollVec.z * strength * rollStrength
                end

                if tti < threatTTILimitFlare then
                    local side = GetMissileSide(I, warning)
                    if side == "left" then
                        fireLeft = true
                    else
                        fireRight = true
                    end
                end
            end
        end
    end

    if threats > 0 then
        DebugLog(I, string.format("Missile Evasion | Threat: %f | Pitch: %.2f | Yaw: %.2f | Roll: %.2f",
            threats, pitchDodge, yawDodge, rollDodge))
    end

    if fireLeft and not fireRight then
        FireFlare(I, leftFlareIndex)
    elseif fireRight then
        FireFlare(I, rightFlareIndex)
    end

    return { pitchDodge, yawDodge, rollDodge }
end

function FriendlyEvasion(I, predictTime)
    local myPos = I:GetConstructCenterOfMass()
    local myVel = I:GetVelocityVector()
    local myFuturePos = myPos + myVel * predictTime

    local avoidanceVec = Vector3(0, 0, 0)
    local threats = 0

    local friendlyCount = I:GetFriendlyCount()
    for i = 0, friendlyCount - 1 do
        local info = I:GetFriendlyInfo(i)
        if info.Valid then
            local otherPos = info.CenterOfMass
            local otherVel = info.Velocity
            local otherFuture = otherPos + otherVel * predictTime

            if (otherPos - myPos).magnitude > 5 then
                local delta = myFuturePos - otherFuture
                local distance = delta.magnitude

                if distance < friendlyAvoidanceTolerance then
                    threats = threats + 1
                    avoidanceVec = avoidanceVec +
                        delta.normalized * ((friendlyAvoidanceTolerance - distance) / friendlyAvoidanceTolerance)
                end
            end
        end
    end

    if threats == 0 then
        return { 0, 0, 0 }
    end

    avoidanceVec = avoidanceVec / threats
    local right = I:GetConstructRightVector()
    local up = I:GetConstructUpVector()
    local forward = I:GetConstructForwardVector()

    local yaw = Vector3.Dot(avoidanceVec, right)
    local pitch = Vector3.Dot(avoidanceVec, up)
    local roll = Vector3.Dot(avoidanceVec, forward)

    totalThreatLevel = 100

    DebugLog(I, string.format("Friendly in range | Pitch: %.2f | Yaw: %.2f | Roll: %.2f", pitch, yaw, roll))

    return {
        pitch * pitchStrength * 5,
        yaw * yawStrength * 5,
        roll * rollStrength * 5
    }
end

function EnemyEvasion(I, predictTime)
    local myPos = I:GetConstructCenterOfMass()
    local myVel = I:GetVelocityVector()
    local myFuturePos = myPos + myVel * predictTime

    local avoidanceVec = Vector3(0, 0, 0)
    local threats = 0

    local mainframes = I:GetNumberOfMainframes()
    for m = 0, mainframes - 1 do
        local targetCount = I:GetNumberOfTargets(m)
        for t = 0, targetCount - 1 do
            local target = I:GetTargetInfo(m, t)
            if target.Valid then
                local otherPos = target.Position
                local otherVel = target.Velocity
                local otherFuture = otherPos + otherVel * predictTime

                local delta = myFuturePos - otherFuture
                local distance = delta.magnitude
                if distance < friendlyAvoidanceTolerance then
                    threats = threats + 1
                    avoidanceVec = avoidanceVec +
                        delta.normalized * ((friendlyAvoidanceTolerance - distance) / friendlyAvoidanceTolerance)
                end
            end
        end
    end

    if threats == 0 then return { 0, 0, 0 } end

    avoidanceVec = avoidanceVec / threats
    local right = I:GetConstructRightVector()
    local up = I:GetConstructUpVector()
    local forward = I:GetConstructForwardVector()

    local yaw = Vector3.Dot(avoidanceVec, right)
    local pitch = Vector3.Dot(avoidanceVec, up)
    local roll = Vector3.Dot(avoidanceVec, forward)

    totalThreatLevel = 100

    DebugLog(I, string.format("Enemy Avoid | P: %.2f Y: %.2f R: %.2f", pitch, yaw, roll))
    return {
        pitch * pitchStrength * 5,
        yaw * yawStrength * 5,
        roll * rollStrength * 5
    }
end

function AdjustJetGenerator(I)
    local energyFraction = I:GetEnergyFraction()

    local desiredValue = 0
    if energyFraction < 1 then
        desiredValue = math.min(60, (math.max(0, (60 - totalThreatLevel))))
    end

    if jetGenerator.value ~= desiredValue then
        jetGenerator.value = desiredValue
    end

    --DebugLog(I, string.format("Jet Generator | Set Fraction : %.2f Total Threat : %.2f Energy : %.2f", jetGenerator.value, totalThreatLevel, energyFraction))
end

local lastChaffActivationTime = -math.huge

function AdjustChaffEmitters(I)
    local currentTime = I:GetTime()

    if totalThreatLevel > 25 then
        chaffEmitter.value = 10
        lastChaffActivationTime = currentTime
    elseif currentTime - lastChaffActivationTime >= 10 then
        chaffEmitter.value = 0
    end
end

function ApplyAdjustedControls(I, controlAdjust)
    local pitchDodge = controlAdjust[1]
    local yawDodge = controlAdjust[2]
    local rollDodge = controlAdjust[3]

    local myVel = I:GetVelocityVector()
    local myPos = I:GetConstructCenterOfMass()

    local verticalSpeed = myVel.y + pitchDodge * 40
    local predictedY = myPos.y + verticalSpeed * predictionTime

    if predictedY < minAltitude then
        pitchDodge = 0
    elseif predictedY > maxAltitude then
        pitchDodge = 0
    end

    if pitchDodge > 0 then
        I:RequestControl(2, 4, math.min(pitchDodge, 1))
    elseif pitchDodge < 0 then
        I:RequestControl(2, 5, math.min(-pitchDodge, 1))
    end

    if yawDodge > 0 then
        I:RequestControl(2, 0, math.min(yawDodge, 1))
    elseif yawDodge < 0 then
        I:RequestControl(2, 1, math.min(-yawDodge, 1))
    end

    if rollDodge > 0 then
        I:RequestControl(2, 2, math.min(rollDodge, 1))
    elseif rollDodge < 0 then
        I:RequestControl(2, 3, math.min(-rollDodge, 1))
    end
end

function sumArrays(a, b)
    local result = {}
    for i = 1, math.min(#a, #b) do
        result[i] = a[i] + b[i]
    end
    return result
end

function isZero(vec)
    return math.abs(vec[1]) < 0.01 and math.abs(vec[2]) < 0.01 and math.abs(vec[3]) < 0.01
end

function DebugLog(I, msg)
    if msg ~= lastDebugMessage then
        I:Log(msg)
        if debug then
            I:LogToHud(msg)
        end
        lastDebugMessage = msg
    end
end

function Update(I)
    if memoryCellInit then
        MemoryCellInit(I)
        memoryCellInit = false
    end

    -- I:Log(I:Component_GetFloatLogic_1(12, 0, 2))
    UpdateMemoryCell(I, 1, 2)

    local controlAdjust = { 0, 0, 0 }

    controlAdjust = sumArrays(controlAdjust, FriendlyEvasion(I, 1))
    controlAdjust = sumArrays(controlAdjust, EnemyEvasion(I, 1))

    if isZero(controlAdjust) then
        controlAdjust = sumArrays(controlAdjust, MissileEvade(I, 0))
    else
        if debug then
            DebugLog(I, "Skipping missile evasion, nearby construct!")
        end
    end

    ApplyAdjustedControls(I, controlAdjust)

    AdjustJetGenerator(I)
    AdjustChaffEmitters(I)

    totalThreatLevel = 0
end
