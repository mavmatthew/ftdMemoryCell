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

local debug = true
local lastDebugMessage = ""

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
                table.insert(memoryCellTransitQueue, {
                    name = cell.name,
                    value = cell.value,
                    transmitValue = cell.rangeStart + cell.value / memoryCellMultiplier / cell.precision
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

    UpdateMemoryCell(I, 1, 2)
    chaffEmitter.value = 10
end
