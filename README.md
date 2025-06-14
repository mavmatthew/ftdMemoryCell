# ftdMemoryCell

## Variable Passing Between LUA and Breadboard in From the Depths

*This is currently a POC and still needs work. It only supports positive integer values and positive drive values. I got as far as I needed for my Vulcan VI. The goal for the memory cell is to be easily applied to any vehicle for any -/+ float values.*

The idea is to allow variables to seamlessly pass to and from both systems. Drives provide us with a highly accurate variable that both systems can access. Using drives we can assign variable values from -1 to 1, including 7 decimal places ( more than 7 proved inaccurate ) allowing for 20,000,001 different values per drive. These values are separated into ranges that can define different variable values. 

To avoid inbound and outbound interference, use different drives. Example, LUA -> Breadboard : secondary drive, Breadboard -> LUA : tertiary drive. For simplicity i kept the subranges the same across both drives.

You can either define your own ranges and omit MemoryCellInit(I), or allow MemoryCellInit(I) to run to assign necessary ranges based on min and max values. The ranges will be logged so that you can reference them for breadboard. The memory cell will automatically update inbound values and send oubound values as long as they are defined properly and added to the memoryCellArray. The majority of user setup will be in breadboard.

---

## Defining a memory cell variable

For example, my Vulcan IV I have defined the following:

```
local targetVolume = { 
    name = "Target Volume", mode = IN, value = 0, prevValue = 0, 
    min = 0, max = 100000, rangeStart = 0, rangeEnd = 0, precision = 1 }

local chaffEmitter = { 
    name = "Chaff Emitter", mode = OUT, value = 0, prevValue = -1, 
    min = 0, max = 10, rangeStart = 0, rangeEnd = 0, precision = 1 }

local jetGenerator = { 
    name = "Jet Generator", mode = OUT, value = 0, prevValue = -1, 
    min = 0, max = 100, rangeStart = 0, rangeEnd = 0, precision = 1 }

local memoryCellArray = { targetVolume, chaffEmitter, jetGenerator }
```

Each variable will be logged (name) : (rangeStart) - (rangeEnd)
```
Target Volume : 0 to 0.01
Chaff Emitter : 0.0100001 - 0.0100011
Jet Generator : 0.0100012 - 0.0100112
```

---

## LUA -> Breadboard
The memory cell automatically encodes, queues and transmits the value when a variable is changed. So all you need to do is set the value 
```
chaffEmitter.value = 10
```

### Decoding Values in Breadboard
*Highly recommend viewing breadboard.png*

Using the outbound drive value ( call it D ) we need to do 2 things: 


1. Check the range. This determines if the value is for the proper variable.
```
(D >= rangeStart) & (D <= rangeEnd) 
```

2. Decode the value. MC = Memory Cell Multiplier, default = 10^7
```
Round((D - rangeStart) * (MC))
```

Pseudo code example of my chaff emitter when the value of 10 is sent
```
If((0.0100011 >= 0.0100001) & (0.0100011 <= 0.0100011)) {
    Breadboard Variable = Round((0.0100011 - 0.0100001) * (10^7))
}
```

## Breadboard -> LUA
Using the inbound drive ( inbound relative to LUA ) we need to do 2 things: 

1. Encode the value (V).
```
(V / MC) + rangeStart
```

2. Set the drive to the encoded value periodically. You cannot pass multiple values at the same time. I use (time % prime number) to determine a unique millisecond.

Values will automatically be set in LUA

---

### Misc
 - prevValue are set to -1 so that the variables are flagged as changed. This allows using the value property to set and transmit the initial value.
 - Precision divides the variable further to occupy a smaller range. For example target volume could be divided by an additional 100 giving us our target volume rounded to the nearest 100. This would only use 0 - 0.0001 instead of 0 to 0.01 ( definitely overkill, as there is plenty of space on the drives, however will be needed for fractions )
 