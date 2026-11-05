local NumberSuffixes = {"K", "M", "B", "T", "Qd", "Qn", "Sx", "Sp", "O", "N", "Dc", "DD"}

function addCommasToNumber(n)
	n = math.floor(n)

	local left, num, right = string.match(tostring(n), '^([^%d]*%d)(%d*)(.-)$')
	return left .. (num:reverse():gsub('(%d%d%d)', '%1,'):reverse()) .. right
end

return function(number : number, SuffixClamp : number)
    number = tonumber(number)

    --> A STRING, like every other path out of here. This used to hand back a raw number for
    --> anything under one, so a caller that did anything string-shaped with the result -- a
    --> concat is fine, a :len() or a string.format("%s") is not -- got a different type for
    --> zero than for everything else, and only ever found out on the one value nobody tests.
    if number < 1 then return tostring(math.round(number)) end

    SuffixClamp = tonumber(SuffixClamp) or 9
    local ClampThreshold = 10 ^ SuffixClamp

    if number < ClampThreshold then
        return addCommasToNumber(number)
    end

    local idx = math.floor( math.log(number, 10) / 3 )
    if idx < 1 then idx = 1 end
    if idx > #NumberSuffixes then idx = #NumberSuffixes end

    local unit = NumberSuffixes[idx]
    local divisor = 10 ^ (idx * 3)
    local short = number / divisor

    local dp = (short < 10 and 2) or (short < 100 and 1) or 0
    local fmt = "%." .. dp .. "f%s"
    unit = " "..unit
    return string.format(fmt, short, unit)
end