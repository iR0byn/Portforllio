-- Services
local players = game:GetService("Players")
local datatstoreservice = game:GetService("DataStoreService")
local httpService = game:GetService("HttpService")
local Analytics = require(game.ServerScriptService.AnalyticsManager)

-- Sharding

local NUM_SHARDS = 250000
local SAVE_STRING = game.ReplicatedStorage.SaveString.Value -- Ensure this exists!
local ITERATION_OF_SAVE = 11
local KEY_PREFIX = "Player:"

-- Base names for each slot's set of sharded DataStores.
local SLOT_1_BASE_NAME = SAVE_STRING .. "1#" .. tostring(ITERATION_OF_SAVE) .. "_Shard"
local SLOT_2_BASE_NAME = SAVE_STRING .. "2#" .. tostring(ITERATION_OF_SAVE) .. "_Shard"
local SLOT_3_BASE_NAME = SAVE_STRING .. "3#" .. tostring(ITERATION_OF_SAVE) .. "_Shard"

-- Default values
local DEFAULT_VALUES = {
	["Points"] = 9,
	["Level"] = 1,
	["Health"] = 100,
	["MaxHealth"] = 100,
	["Mana"] = 1,
	["Manastat"] = 1,
	["MaxMana"] = 1,
	["StatPoints"] = 1,
	["Hair"] = 2,

	["instantlylaunch"] = true,
	["canattack"] = true,
	["cantakedamage"] = true,
	["canMove"] = true,
	["UISTATE"] = 3,
	["Saveslots"] = "Slot1",
	["Saveslotss"] = "Slot1",
	["Exp"] = 1,
	["Slot1"] = "One",
	["Slot2"] = "Two",
	["Slot3"] = "Three",
	["Slot4"] = "Four",
	["Slot5"] = "Five",
	["Slot6"] = "Six",
	["Slot7"] = "Seven",
	["Reputation"] = 10,
}

-- Gets the path relative to pdata (e.g., "keys/Slot1/Sword")
local function getRelativePath(obj, root)
	if obj == root then
		return ""
	end
	local path = obj.Name
	local current = obj.Parent
	while current and current ~= root do
		path = current.Name .. "/" .. path
		current = current.Parent
	end
	return path
end

local function shouldSkipSave(obj)
	-- 1. Always save if there are custom Attributes
	local attrs = obj:GetAttributes()
	if next(attrs) ~= nil then
		return false
	end

	-- 2. Always save Folders if they are not pdata itself (to preserve hierarchy)
	if obj:IsA("Folder") and obj.Name ~= "pdata" then
		return false
	end

	-- 3. Check specific defaults
	local specialDefault = DEFAULT_VALUES[obj.Name]
	if specialDefault ~= nil then
		return obj.Value == specialDefault
	end

	-- 4. Check Generic Defaults
	if obj:IsA("NumberValue") or obj:IsA("IntValue") then
		return obj.Value == 0
	elseif obj:IsA("BoolValue") then
		return obj.Value == false
	elseif obj:IsA("StringValue") then
		return obj.Value == ""
	end

	return false
end

local function getPlayerDataStore(player: Player, slotNumber: number)
	if not player or not slotNumber then
		return nil
	end
	local shardId = player.UserId % NUM_SHARDS

	local dataStoreName
	if slotNumber == 1 then
		dataStoreName = SLOT_1_BASE_NAME .. shardId
	elseif slotNumber == 2 then
		dataStoreName = SLOT_2_BASE_NAME .. shardId
	elseif slotNumber == 3 then
		dataStoreName = SLOT_3_BASE_NAME .. shardId
	else
		warn("Invalid slot number provided:", slotNumber)
		return nil
	end

	return datatstoreservice:GetDataStore(dataStoreName)
end

local function save(player, Slot)
	if not Slot or Slot == "" then
		return
	end

	local slotNumber = tonumber(string.sub(Slot, 5)) or tonumber(string.sub(Slot, 6))
	if not slotNumber then
		return
	end

	local targetDataStore = getPlayerDataStore(player, slotNumber)
	if not targetDataStore then
		return
	end

	local key = KEY_PREFIX .. tostring(player.UserId)
	local dataArray = {}

	local pdata = player:FindFirstChild("pdata")
	if not pdata then
		return
	end

	-- Iterate through Descendants
	for _, obj in ipairs(pdata:GetDescendants()) do
		if obj:IsA("ValueBase") or obj:IsA("Folder") then
			-- Skip Vector3/CFrame as before
			if obj:IsA("Vector3Value") or obj:IsA("CFrameValue") then
				continue
			end

			if shouldSkipSave(obj) then
				continue
			end

			local relPath = getRelativePath(obj, pdata)

			-- Value logic: Folders don't have a .Value property
			-- ObjectValue holds an Instance reference which cannot be JSON-encoded.
			local valToSave = nil
			if obj:IsA("ValueBase") and not obj:IsA("ObjectValue") then
				valToSave = obj.Value
			end

			table.insert(dataArray, {
				valToSave, -- [1] Value
				obj.Name, -- [2] Name
				relPath, -- [3] FULL RELATIVE PATH (Replacing Parent Name)
				obj.ClassName, -- [4] Class
				obj:GetAttributes(), -- [5] Attributes
			})
		end
	end

	local success, dataToSave = pcall(function()
		return httpService:JSONEncode(dataArray)
	end)

	if not success then
		warn("Encode failed")
		return
	end

	-- Retry loop
	local attempts = 0
	local maxAttempts = 3
	repeat
		attempts = attempts + 1
		success = pcall(function()
			targetDataStore:SetAsync(key, dataToSave)
		end)
		if not success and attempts < maxAttempts then
			task.wait(2)
		end
	until success or attempts >= maxAttempts

	if success then
		print("Successfully saved data for " .. player.Name .. " in " .. Slot)
	else
		warn("Failed to save data for " .. player.Name)
	end
end

-- RemoteEvent Connection
game.ReplicatedStorage.Getdata.OnServerEvent:Connect(function(player, entitie, Purpose, Slot)
	local slotNumber = tonumber(string.sub(Slot, 5)) or tonumber(string.sub(Slot, 6))
	if not slotNumber then
		return
	end

	local targetDataStore = getPlayerDataStore(player, slotNumber)
	local key = KEY_PREFIX .. tostring(player.UserId)

	if Purpose == "Check" then
		-- (Existing Check Logic remains mostly the same, simplified for brevity)
		local success, jsonData = pcall(function()
			return targetDataStore:GetAsync(key)
		end)
		local data
		if success and jsonData then
			data = httpService:JSONDecode(jsonData)
		end

		if not data then
			if entitie and entitie:FindFirstChild("Imageg") then
				entitie.Imageg.Visible = false
			end
		else
			if entitie and entitie:FindFirstChild("Imageg") then
				entitie.Imageg.Visible = true
				local race, level = "N/A", 1
				for _, obj in ipairs(data) do
					if obj[2] == "Race" then
						race = obj[1]
					elseif obj[2] == "Level" then
						level = obj[1]
					end
				end
				entitie.Imageg.Race.Race.Text = tostring(race)
				entitie.Imageg.Level.Level.Text = tostring(level)
			end
		end
	elseif Purpose == "Load" then
		player:FindFirstChild("Saveslots").Value = Slot
		player:FindFirstChild("Saveslots"):FindFirstChild("Saveslotss").Value = Slot

		local success, jsonData = pcall(function()
			return targetDataStore:GetAsync(key)
		end)
		if not success then
			warn("Load failed")
			return
		end

		local data
		if jsonData then
			success, data = pcall(function()
				return httpService:JSONDecode(jsonData)
			end)
		end

		if not data or #data == 0 then
			print("No data found for " .. player.Name .. ". Using defaults.")
			return
		end

		print("Loading data for " .. player.Name .. "...")
		local pdataFolder = player:WaitForChild("pdata")

		for _, objData in ipairs(data) do
			local value, name, pathInfo, className, attributes = table.unpack(objData)

			-- pathInfo might be the old "ParentName" OR the new "Relative/Path/String"

			local parentInstance = nil

			-- NEW LOGIC: Check if it's a path or just a name
			if string.find(pathInfo, "/") then
				-- It is a path (e.g. "keys/Slot1/Sword/Summon")
				-- We need to traverse the path to find the parent, creating folders if missing
				local parts = string.split(pathInfo, "/")
				local traverse = pdataFolder

				-- parts: {"keys", "Slot1", "Sword", "Summon"}

				for i = 1, #parts - 1 do
					local partName = parts[i]
					local nextObj = traverse:FindFirstChild(partName)

					if not nextObj then
						-- if the parent was also saved.
						local newFolder = Instance.new("Folder")
						newFolder.Name = partName
						newFolder.Parent = traverse
						nextObj = newFolder
					end
					traverse = nextObj
				end
				parentInstance = traverse
			else
				-- if  it is the OLD format (Just Parent Name) or a direct child of pdata

				parentInstance = pdataFolder:FindFirstChild(pathInfo, true)

				-- Special fallback: if pathInfo is 'pdata', the parent is the folder itself
				if pathInfo == "pdata" then
					parentInstance = pdataFolder
				end
			end

			-- Now create/update the actual object
			if parentInstance then
				local valueInstance = parentInstance:FindFirstChild(name)

				if not valueInstance then
					-- Create it if it doesn't exist
					valueInstance = Instance.new(className)
					valueInstance.Name = name
					valueInstance.Parent = parentInstance
				end

				-- Apply Value (if it's a ValueBase)
				if value ~= nil and valueInstance:IsA("ValueBase") then
					valueInstance.Value = value
				end

				-- Apply Attributes
				if attributes then
					for attrName, attrValue in pairs(attributes) do
						valueInstance:SetAttribute(attrName, attrValue)
					end
				end
			else
				warn("Could not find parent for: " .. name .. " (Path/Parent: " .. tostring(pathInfo) .. ")")
			end
		end

		print("Finished loading data for " .. player.Name)
		game.ReplicatedStorage.Getdata:FireClient(player, "load")
	elseif Purpose == "Save" then
		save(player, Slot)
	elseif Purpose == "Character" then
		task.wait()
		game.ReplicatedStorage.Getdata:FireClient(player, "load")
	end
end)

local function onPlayerLeave(player)
	local saveslots = player:FindFirstChild("Saveslots")

	-- Comprehensive session analytics on leave
	Analytics.trackPlayerLeft(player)

	if saveslots then
		local saveslotss = saveslots:FindFirstChild("Saveslotss")
		if saveslotss and saveslotss.Value ~= "" then
			save(player, saveslotss.Value)
		end
	end
end

game:BindToClose(function()
	-- Spawn a save for each player in parallel so all finish within the time budget
	local threads = {}
	for _, player in ipairs(players:GetPlayers()) do
		local t = task.spawn(onPlayerLeave, player)
		table.insert(threads, t)
	end
	-- Give saves time to complete (DataStore writes are async under the hood)
	task.wait(3)
end)

game.Players.PlayerRemoving:Connect(onPlayerLeave)
