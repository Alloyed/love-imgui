local util = require 'bindings2.util'

local SKIP_FUNCTIONS = {
}

local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

local function findRegions(source, tag)
	local regions = {}
	local regionPattern = tag .. "%s*%S+%s*%b{}"
	local regionNamePattern = tag .. " (%S+)"
	local start, stop = source:find(regionPattern)
	while start do
		local name = source:match(regionNamePattern, start)
		local region = {
			start = start,
			stop = stop,
			name = name,
			type = tag,
		}
		table.insert(regions, region)
		start, stop = source:find(regionPattern, stop + 1)
	end
	return regions
end

local function findEnumValues(source, enumData)
	source = source:match("%b{}"):sub(2, -2)
	enumData.values = {}
	local lastValue = -1
	for line in source:gmatch("[^\n]+") do
		local left, comment = line:match("^%s*([^/]-)%s+//%s*(.-)%s*$")
		if comment then
			line = left
		end
		line = trim(line)
		if line ~= "" then
			local name, value
			if line:find("=") then
				name, value = line:match("^%s*(%S+)%s*=%s*([^,]+)%s*%,?")
			else
				name = line:match("^%s*([^,]+)%s*%,?")
				value = lastValue + 1
			end
			lastValue = tonumber(value)
			local cname = name
			name = name:gsub(enumData.name, "")
			if name ~= "COUNT" then
				enumData.values[name] = {cname = cname, value = value, comment = comment}
			end
		end
	end
end

local function findEnums(source)
	local enums = {}
	local enumPattern = "enum%s*%S+%s*%b{}"
	local enumNamePattern = "enum (%S+)"
	local start, stop = source:find(enumPattern)
	while start do
		local name = source:match(enumNamePattern, start)
		local enumData = { name = name }
		findEnumValues(source:sub(start, stop), enumData)
		start, stop = source:find(enumPattern, stop + 1)
		table.insert(enums, enumData)
	end
	return enums
end

local function getRegionsForPosition(data, position)
	local matchingRegions = {}
	for _, region in ipairs(data.classes) do
		if region.start < position and region.stop > position then
			table.insert(matchingRegions, region)
		end
	end
	for _, region in ipairs(data.structs) do
		if region.start < position and region.stop > position then
			table.insert(matchingRegions, region)
		end
	end
	for _, region in ipairs(data.namespaces) do
		if region.start < position and region.stop > position then
			table.insert(matchingRegions, region)
		end
	end
	return matchingRegions
end

local function isMethod(regions)
	for _, region in ipairs(regions) do
		if region.type == "struct" or region.type == "class" then
			return true
		end
	end
	return false
end

local function matchMany(s, searchStart, ...)
	for i = 1, select('#', ...) do
		local pat = select(i, ...)
		local start, stop = s:find(pat, searchStart)
		if start then
			return s:match(pat, searchStart), start, stop
		end
	end
	return nil
end

local function matchCType(s, start)
	-- ctypes are actually much more complex that this, but this is ok for now
	-- TODO: function pointer syntax? woah
	return matchMany(s, start,
		"^%s-(const %w+%*?&?)", -- const type
		"^%s-(%w+%*?&?)") -- normal type
end

local function splitArgs(args)
	-- temporarily remove nested arglists
	local search = args:gsub("%b()", function(s)
		return string.rep("$", s:len())
	end)

	local arglist = {}
	local start, stop = search:find("[^,]+")
	while start do
		table.insert(arglist, args:sub(start, stop))
		start, stop = search:find("[^,]+", stop + 1)
	end
	return arglist
end

local function matchCArgs(line, start)
	-- likewise, simplifying so I can get results
	local varargs = false
	local args = splitArgs(line:match("%b()", start):sub(2, -2))
	for i, arg in ipairs(args) do
		if trim(arg) == "..." then
			varargs = true
			args[i] = nil
		elseif arg:find("%b()") and not arg:find("=") then
			-- TODO: function pointers
			args[i] = {
				type = arg,
				name = "myfn",
			}
		else
			local eqstart, eqstop = arg:find("%s*=%s*")
			local default = ""
			if eqstart then
				default = trim(arg:sub(eqstop+1))
				arg = arg:sub(1, eqstart-1)
			end

			local namestart, namestop = arg:find("%S+$")
			local argname = arg:sub(namestart, namestop)
			local argtype = trim(arg:sub(1, namestart-1))

			if argname:match("%]$") then
				local arraySize
				argname, arraySize = argname:match("^([^%[]+)%[(.-)%]$")
				argtype = argtype .. "[" .. arraySize .. "]"
			end

			args[i] = {
				type = argtype,
				name = argname,
				default = default ~= "" and default,
			}
		end
	end
	return args, varargs
end

local function parseImguiFunction(line)
	local _, apiStop = line:find("IMGUI_API")
	local returnType, _, returnStop = matchCType(line, apiStop + 1)
	local name = line:match("%w+", returnStop + 1)
	local _, nameStop = line:find("%w+", returnStop + 1)
	local args, isVarargs = matchCArgs(line, nameStop+1)
	local comment = line:match("//(.+)")
	return {
		rawLine = line,
		returnType = returnType,
		name = name,
		arguments = args,
		isVarargs = isVarargs,
		comment = comment,
	}
end

local function getNamespaceFromRegions(regions)
	table.sort(regions, function(left, right) return left.start < right.start end)
	local r = {}
	for _, region in ipairs(regions) do
		table.insert(r, region.name)
	end
	return table.concat(r, "::")
end

local Parse = {}
function Parse.parseHeader(fname)
	util.logf("Parsing %s", fname)
	local file = assert(io.open(fname, 'r'))
	local source = file:read('*a')
	file:close()

	-- manually remove obsolete functions
	local obsoleteRegionPattern = "#ifndef IMGUI_DISABLE_OBSOLETE_FUNCTIONS.-#endif"
	source = source:gsub(obsoleteRegionPattern, "")

	local data = {}
	data.functions = {}
	data.namespaces = findRegions(source, "namespace")
	data.structs = findRegions(source, "struct")
	data.classes = findRegions(source, "class")
	data.enums = findEnums(source)

	local start, stop = source:find("[^\n]+")
	while start do
		local line = source:sub(start, stop)
		if line:match("^%s*IMGUI_API") then
			local regions = getRegionsForPosition(data, start)
			if not isMethod(regions) then
				local fnData = parseImguiFunction(line)
				fnData.namespace = getNamespaceFromRegions(regions)
				if not SKIP_FUNCTIONS[fnData.name] and not fnData.name:match("V$") then
					table.insert(data.functions, fnData)
				end
			end
		end
		start, stop = source:find("[^\n]+", stop + 1)
	end

	return data
end

return Parse