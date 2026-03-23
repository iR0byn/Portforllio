local isMaster = not script.Parent:IsA("Actor")

if not isMaster then
	-- WORKER CONTEXT
	local actor = script.Parent
	local workerTaskEvent = actor:WaitForChild("WorkerTask")
	local workerResultEvent = actor:WaitForChild("WorkerResult")
	local PathfindingService = game:GetService("PathfindingService")
	
	workerTaskEvent.Event:Connect(function(jobId, jobType, data)
		if jobType == "FindClosestStone" then
			task.desynchronize() -- Enter Parallel Execution
			local closestDist = data.range
			local closestRock = nil
			
			local rootPos = data.rootPos
			local blacklisted = data.blacklisted
			
			for _, rock in ipairs(data.rocksToCheck) do
				if rock == blacklisted then continue end
				
				-- data.rocksToCheck is a pre-filtered list from the SpatialGrid
				local rockPos = data.rockPositions[rock]
				if not rockPos then continue end
				
				local dist = (rockPos - rootPos).Magnitude
				if dist < closestDist then
					closestDist = dist
					closestRock = rock
				end
			end
			
			task.synchronize() -- Enter Main Thread Execution
			workerResultEvent:Fire(jobId, closestRock)
		
		elseif jobType == "ComputePath" then
			local pathSuccess = false
			local waypoints = nil
			pcall(function()
				local path = PathfindingService:CreatePath({
					AgentRadius = 2,
					AgentHeight = 5,
					AgentCanJump = data.AllowJumping,
					WaypointSpacing = math.huge,
					Costs = { Water = 20 },
				})
				path:ComputeAsync(data.startPos, data.endPos)
				if path.Status == Enum.PathStatus.Success then
					pathSuccess = true
					waypoints = path:GetWaypoints()
				end
			end)
			workerResultEvent:Fire(jobId, {success = pathSuccess, waypoints = waypoints})
		end
	end)
	
	return -- Stop worker from executing the main server logic
end

-- MASTER CONTEXT
local WORKER_COUNT = 8
local workerActors = {}
local workerIdleQueue = {}
local workerResultConns = {}

local nextJobId = 1
local activeJobs = {}

local function dispatchWorkerJob(jobType, data, callback)
	local jobId = nextJobId
	nextJobId = nextJobId + 1
	
	activeJobs[jobId] = callback
	
	local worker = nil
	if #workerIdleQueue > 0 then
		worker = table.remove(workerIdleQueue, 1)
	else
		-- Round robin if heavy load
		worker = workerActors[(jobId % WORKER_COUNT) + 1]
	end
	
	worker.IsBusy = true
	worker.TaskEvent:Fire(jobId, jobType, data)
end

local function setupWorkers()
	for i = 1, WORKER_COUNT do
		local actor = Instance.new("Actor")
		actor.Name = "NpcBrainWorker_" .. i
		
		local workerTaskEvent = Instance.new("BindableEvent")
		workerTaskEvent.Name = "WorkerTask"
		workerTaskEvent.Parent = actor
		
		local workerResultEvent = Instance.new("BindableEvent")
		workerResultEvent.Name = "WorkerResult"
		workerResultEvent.Parent = actor
		
		local clone = script:Clone()
		clone.Parent = actor
		actor.Parent = script.Parent
		
		local workerObj = {
			Actor = actor,
			TaskEvent = workerTaskEvent,
			ResultEvent = workerResultEvent,
			Id = i,
			IsBusy = false
		}
		
		workerResultConns[i] = workerResultEvent.Event:Connect(function(jobId, result)
			workerObj.IsBusy = false
			table.insert(workerIdleQueue, workerObj)
			if activeJobs[jobId] then
				activeJobs[jobId](result)
				activeJobs[jobId] = nil
			end
		end)
		
		table.insert(workerActors, workerObj)
		table.insert(workerIdleQueue, workerObj)
	end
end
setupWorkers()

-- Services
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local PhysicsService = game:GetService("PhysicsService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local SpatialGrid = require(script.Parent:WaitForChild("SpatialGrid"))

local ResourceGrid = SpatialGrid.new(200) -- 200 stud cells to capture a large area with few cell lookups

CollectionService:GetInstanceAddedSignal("Stone"):Connect(function(rock)
	local rockPart = rock:FindFirstChild("HumanoidRootPart") or rock.PrimaryPart or rock:FindFirstChildWhichIsA("BasePart")
	if rockPart then
		ResourceGrid:Insert(rock, rockPart.Position)
	end
end)

CollectionService:GetInstanceRemovedSignal("Stone"):Connect(function(rock)
	local rockPart = rock:FindFirstChild("HumanoidRootPart") or rock.PrimaryPart or rock:FindFirstChildWhichIsA("BasePart")
	if rockPart then
		ResourceGrid:Remove(rock, rockPart.Position)
	end
end)

task.spawn(function()
	for _, rock in ipairs(CollectionService:GetTagged("Stone")) do
		local rockPart = rock:FindFirstChild("HumanoidRootPart") or rock.PrimaryPart or rock:FindFirstChildWhichIsA("BasePart")
		if rockPart then
			ResourceGrid:Insert(rock, rockPart.Position)
		end
	end
end)



-- tweak these without digging through the actual logic
local Config = {
	-- work hours
	WORK_START_HOUR = 9,
	WORK_END_HOUR = 18,
	SLEEP_START_HOUR = 22,
	DAY_START_HOUR = 7,

	-- pathfinding
	MAX_PATHFINDING_FAILS = 5, -- after this many fails just tp them home
	PATHFINDING_COOLDOWN = 3,
	ALLOW_JUMPING = true,

	-- job stuff
	RESOURCE_SEARCH_COOLDOWN = 5,
	MAX_RESOURCE_SEARCH_RANGE = 300,
	CAMPING_RANGE = 20, -- how close a miner waits near a respawn spot
	GO_HOME_RETRY_TIME = 10,

	CAVE_DETECTION_RANGE = 80,

	VOID_RESCUE_HEIGHT = -100, -- fell through map, rescue them

	-- loop speeds
	MAIN_LOOP_WAIT = 0.5,
	ECONOMY_LOOP_WAIT = 60,
	JOB_DISPATCH_WAIT = 4,

	HOUSES_PER_FRAME_GEN = 10,
	COMMON_SPAWN_WEIGHT = 8,

	-- how much time the brain loop gets per frame before yielding (8ms)
	BRAIN_TIME_BUDGET = 0.008,

	-- arms/legs/head dont need to collide with anything, saves physics time
	NON_ESSENTIAL_LIMBS = {
		"Left Arm",
		"Right Arm",
		"Left Leg",
		"Right Leg",
		"Head",
	},

	-- hardcoded since server now plays anims directly
	MINING_SWING_DURATION = 1,
}

local NPC_GROUP = "NPCs"
local RAYCAST_IGNORED_GROUP = "RaycastIgnored"

local PathCache = {} -- [hash] = { timestamp = os.clock(), waypoints = {} }
local CACHE_EXPIRY = 15
local handlePathFailure -- Forward declaration for handlePath

local mapGrid = SpatialGrid.new(100)

task.wait() -- let the engine settle before messing with collision groups

-- adventurers = Adventurer1, Adventurer2 ...  bandits = Bandit1, Bandit2 ...
-- both use prefix matching since they have numbered suffixes
local function isSelfManaged(npc)
	return string.find(npc.Name, "Adventurer") ~= nil or string.find(npc.Name, "Bandit") ~= nil
end

local function setupCollisionGroups()
	local function register(name)
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end

	-- npcs shouldnt push each other or block raycasts
	pcall(function()
		register(NPC_GROUP)
		register(RAYCAST_IGNORED_GROUP)
		PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, NPC_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(NPC_GROUP, RAYCAST_IGNORED_GROUP, false)
	end)
end

setupCollisionGroups()

-- pathfinding requests go here and get processed in batches
-- doing them all at once tanked performance
local pathfindingQueue = {}

-- shared raycast params, excludes npcs so they dont block their own raycasts
local PATH_RAYCAST_PARAMS = RaycastParams.new()
PATH_RAYCAST_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
PATH_RAYCAST_PARAMS.CollisionGroup = NPC_GROUP

-- animation is 100% client-side now
-- server just sets this attribute and the client reads it to play animations
local function setAnimState(npc, state)
	npc:SetAttribute("AnimState", state)
end

-- run this once per npc when it spawns
local function optimizeHumanoid(npc)
	local isAdventurer = isSelfManaged(npc)

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")

	if not rootPart then
		warn("[NPC] " .. npc.Name .. " is missing HumanoidRootPart — destroying.")
		npc:Destroy()
		return
	end

	local nonEssentialSet = {}
	for _, limb in ipairs(Config.NON_ESSENTIAL_LIMBS) do
		nonEssentialSet[limb] = true
	end

	rootPart.CollisionGroup = NPC_GROUP
	rootPart.Anchored = false

	-- let the engine assign network ownership to the closest player
	-- way cheaper than server-owning every npc

	for _, part in ipairs(npc:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = NPC_GROUP

			-- client manages visibility, server just disables shadows
			part.CastShadow = false

			-- only root and torso need real collisions
			if nonEssentialSet[part.Name] then
				part.CanCollide = false
			end

			-- accessory handles dont need any physics at all
			if part.Parent:IsA("Accessory") then
				part.CanQuery = false
				part.CanTouch = false
				part.CanCollide = false
			end

			-- make invisible on server, save original for client
			part:SetAttribute("OriginalTransparency", part.Transparency)
			part.Transparency = 1
		elseif part:IsA("Decal") or part:IsA("Texture") then
			part:SetAttribute("OriginalTransparency", part.Transparency)
			part.Transparency = 1
		end
	end

	-- start in idle state, client reads this for animations
	setAnimState(npc, "Idle")

	if humanoid then
		-- sometimes a rogue script gets parented to the humanoid, kill it
		local rogueScript = humanoid:FindFirstChild("Script")
		if rogueScript and rogueScript:IsA("Script") then
			rogueScript:Destroy()
		end

		-- adventurers need these for combat, regular npcs dont
		if not isAdventurer then
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Flying, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Swimming, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
			humanoid.BreakJointsOnDeath = false
		end
	end

	-- tag so job dispatchers can use GetTagged instead of looping everything
	if not npc:HasTag("Npc") then
		npc:AddTag("Npc")
	end

	local job = npc:GetAttribute("Job")
	if job == "Miner" and not npc:HasTag("Miner") then
		npc:AddTag("Miner")
	elseif job == "Walker" and not npc:HasTag("Walker") then
		npc:AddTag("Walker")
	end
end

-- tell the client to stop showing mining animation
local function stopMiningAnimation(npc)
	setAnimState(npc, "Idle")
end

-- helpers for reading/writing ObjectValues as a poor mans pointer
local function setObjectValue(parent, name, value)
	local val = parent:FindFirstChild(name)
	if value == nil then
		if val then
			val:Destroy()
		end
		return
	end
	if not val then
		val = Instance.new("ObjectValue")
		val.Name = name
		val.Parent = parent
	end
	val.Value = value
end

local function getObjectValue(parent, name)
	local val = parent:FindFirstChild(name)
	if val and val:IsA("ObjectValue") then
		return val.Value
	end
	return nil
end

-- raycast down to find the floor y at a given x,z
local function getGroundHeight(x, z, startHeight, offset)
	local castOriginY = startHeight + (offset or 10)
	local origin = Vector3.new(x, castOriginY, z)
	local direction = Vector3.new(0, -60, 0)
	local result = workspace:Raycast(origin, direction, PATH_RAYCAST_PARAMS)
	if result then
		return result.Position.Y, true
	end
	return startHeight, false
end

-- random point near a position, snapped to ground so they dont float
local function getJitteredPosition(position, radius)
	local randomAngle = math.random() * 2 * math.pi
	local randomRadius = math.random() * radius
	local targetX = position.X + math.cos(randomAngle) * randomRadius
	local targetZ = position.Z + math.sin(randomAngle) * randomRadius
	local groundY, foundGround = getGroundHeight(targetX, targetZ, position.Y, 20)
	if foundGround then
		return Vector3.new(targetX, groundY, targetZ)
	end
	return position
end

-- clear both sides of the claim so another miner can take the rock
local function releaseClaimedResource(npc)
	local claimedResource = getObjectValue(npc, "ClaimedResource")
	if claimedResource then
		if getObjectValue(claimedResource, "TargetedBy") == npc then
			setObjectValue(claimedResource, "TargetedBy", nil)
		end
		setObjectValue(npc, "ClaimedResource", nil)
	end
end

-- clones the tool server side for the hitbox, visuals are handled on client
local function equipMinerTool(npc)
	local existing = npc:FindFirstChild("Miners Mantle")
	if existing then
		stopMiningAnimation(npc)
		return existing
	end

	local itemsFolder = ReplicatedStorage:FindFirstChild("Items")
	if not itemsFolder then
		return nil
	end

	local itemTemplate = itemsFolder:FindFirstChild("Miners Mantle", true)
	if not itemTemplate then
		return nil
	end

	local tool = itemTemplate:Clone()
	
	for _, part in ipairs(tool:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("Decal") or part:IsA("Texture") then
			part:SetAttribute("OriginalTransparency", part.Transparency)
			part.Transparency = 1
			if part:IsA("BasePart") then
				part.CastShadow = false
			end
		end
	end
	
	tool.Parent = npc

	-- wire up the hitbox motor
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if rootPart and tool:FindFirstChild("Hitbox") and tool.Hitbox:FindFirstChild("Motor6D") then
		tool.Hitbox.Motor6D.Part0 = rootPart
	end

	-- right arm attachment so the client renders it correctly
	local rightArm = npc:FindFirstChild("Right Arm")
	if rightArm and tool:FindFirstChild("Attach") then
		tool.Attach.Part0 = rightArm
	end

	setAnimState(npc, "MineIdle")

	tool:SetAttribute("currentM1", 0)
	tool:SetAttribute("Debounce", false)

	return tool
end

local function unequipMinerTool(npc)
	local tool = npc:FindFirstChild("Miners Mantle")

	-- tell client to stop all tool animations
	setAnimState(npc, "Idle")

	if tool then
		tool:Destroy()
	end
end

-- last resort, just shove them inside their house
local function teleportNpcHome(npc)
	releaseClaimedResource(npc)
	unequipMinerTool(npc)

	-- adventurers handle themselves
	if isSelfManaged(npc) then
		return
	end

	local homeValue = npc:FindFirstChild("Homeval")
	if not (homeValue and homeValue.Value) then
		npc:SetAttribute("Task", "Idle")
		return
	end

	local house = homeValue.Value
	local door = house:FindFirstChild("Door")
	if door then
		local rootPart = npc:FindFirstChild("HumanoidRootPart")
		if rootPart then
			local insidePosition = door.CFrame * CFrame.new(3, 0, 0)
			npc:PivotTo(insidePosition)
			npc:SetAttribute("IsAsleep", true)
			rootPart.AssemblyLinearVelocity = Vector3.zero
			npc:SetAttribute("PathfindingFails", 0)
			npc:SetAttribute("NeedsToGoHome", nil)
			npc:SetAttribute("Task", "Idle")
		end
	else
		local rootPart = npc:FindFirstChild("HumanoidRootPart")
		if rootPart then
			npc:SetAttribute("IsAsleep", true)
		end
		npc:SetAttribute("Task", "Idle")
		npc:SetAttribute("PathfindingFails", 0)
		npc:SetAttribute("NeedsToGoHome", nil)
	end
end

-- if theyre stuck underground near a cave entrance, pop them out
local function ejectFromCave(npc)
	local caveEntrances = workspace:FindFirstChild("CaveEntrances")
	if not caveEntrances then
		return false
	end

	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return false
	end

	for _, cave in ipairs(caveEntrances:GetChildren()) do
		local p1 = cave:FindFirstChild("Point1")
		local p2 = cave:FindFirstChild("Point2")
		if p1 and p2 then
			local dist = (rootPart.Position - p1.Position).Magnitude
			if dist <= Config.CAVE_DETECTION_RANGE then
				npc:PivotTo(p2.CFrame + Vector3.new(0, 3, 0))
				npc:SetAttribute("PathfindingFails", 0)
				npc:SetAttribute("Task", "Idle")
				return true
			end
		end
	end
	return false
end

-- if nothing is in the way just walk straight there, skip the full pathfind
local function canWalkDirectly(startPos, endPos)
	local direction = endPos - startPos
	if direction.Magnitude > 100 then
		return false
	end
	local result = workspace:Raycast(startPos, direction, PATH_RAYCAST_PARAMS)
	return result == nil
end

local function directMove(npc, destination, callback)
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not rootPart then return end

	local humanoid = npc:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	humanoid:MoveTo(destination)
	
	local connection
	local timeout
	
	local function cleanup()
		if connection then 
			connection:Disconnect() 
			connection = nil
		end
		if timeout then 
			local t = timeout
			timeout = nil
			if coroutine.running() ~= t then
				pcall(task.cancel, t)
			end
		end
	end
	
	connection = humanoid.MoveToFinished:Connect(function(reached)
		cleanup()
		if callback then callback(reached) end
	end)
	
	timeout = task.delay(5, function()
		cleanup()
		if npc and npc.Parent then
			humanoid:MoveTo(rootPart.Position)
		end
		if callback then callback(false) end
	end)
end

local function handlePath(npc, waypoints, callback)
	local index = 2 -- skip starting waypoint
	local function nextWaypoint()
		if not npc or not npc.Parent then return end
		if index > #waypoints then
			npc:SetAttribute("Task", "Idle")
			if callback then callback() end
			return
		end
		
		local wp = waypoints[index]
		local dest = wp.Position
		
		if wp.Action == Enum.PathWaypointAction.Jump then
			local hum = npc:FindFirstChildOfClass("Humanoid")
			if hum then hum.Jump = true end
		end
		
		index = index + 1
		directMove(npc, dest, function(reached)
			if reached then
				nextWaypoint()
			else
				handlePathFailure(npc)
			end
		end)
	end
	
	npc:SetAttribute("Task", "Walking")
	nextWaypoint()
end

local function getCachedPath(startPos, endPos)
	local hash = string.format("%.0f,%.0f,%.0f_%.0f,%.0f,%.0f", startPos.X/10, startPos.Y/10, startPos.Z/10, endPos.X/10, endPos.Y/10, endPos.Z/10)
	local cache = PathCache[hash]
	if cache and (os.clock() - cache.timestamp) < CACHE_EXPIRY then
		return cache.waypoints, hash
	end
	return nil, hash
end

local function setCachedPath(hash, waypoints)
	PathCache[hash] = {
		timestamp = os.clock(),
		waypoints = waypoints
	}
end

local function requestWalkTo(npc, destinationPosition, onCompleteCallback)
	if isSelfManaged(npc) then
		return
	end

	-- already waiting, dont queue again
	local currentTask = npc:GetAttribute("Task")
	if currentTask == "Pathing Queued" then
		return
	end

	npc:SetAttribute("Task", "Pathing Queued")
	table.insert(pathfindingQueue, {
		npc = npc,
		destination = destinationPosition,
		callback = onCompleteCallback,
		timestamp = os.clock(),
	})
end

handlePathFailure = function(npc)
	releaseClaimedResource(npc)
	local fails = (npc:GetAttribute("PathfindingFails") or 0) + 1
	npc:SetAttribute("PathfindingFails", fails)

	if fails >= Config.MAX_PATHFINDING_FAILS then
		-- try cave eject first, if that doesnt work just send them home
		if not ejectFromCave(npc) then
			teleportNpcHome(npc)
		end
	else
		local wasGoingHome = npc:GetAttribute("Task") == "Going Home"
		npc:SetAttribute("Task", "Cooldown")
		npc:SetAttribute("CooldownEndTime", os.clock() + Config.PATHFINDING_COOLDOWN)
		if wasGoingHome then
			npc:SetAttribute("NeedsToGoHome", true)
		end
	end
end

local function processPathfindingRequest(request)
	local npc = request.npc
	if not npc or not npc.Parent then return end

	-- target got destroyed while they were waiting in queue
	local targetResource = getObjectValue(npc, "ClaimedResource")
	if targetResource and not targetResource:IsDescendantOf(workspace) then
		releaseClaimedResource(npc)
		npc:SetAttribute("Task", "WaitingForRespawn")
		return
	end

	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		npc:SetAttribute("Task", "Idle")
		return
	end

	npc:SetAttribute("Task", "Walking")
	
	local startPos = rootPart.Position
	local dest = request.destination

	local _, destIsSafe = getGroundHeight(dest.X, dest.Z, dest.Y)
	if not destIsSafe then
		npc:SetAttribute("Task", "Idle")
		return
	end

	local dist = (startPos - dest).Magnitude
	if dist < 25 and canWalkDirectly(startPos, dest) then
		directMove(npc, dest, request.callback)
		return
	end

	local pathId = os.clock()
	npc:SetAttribute("CurrentPathId", pathId)
	
	local cachedWaypoints, cacheHash = getCachedPath(startPos, dest)
	if cachedWaypoints then
		npc:SetAttribute("PathfindingFails", 0)
		handlePath(npc, cachedWaypoints, request.callback)
		return
	end

	-- Dispatch Async Worker Thread for Pathfinding
	dispatchWorkerJob("ComputePath", {
		startPos = startPos, 
		endPos = dest, 
		AllowJumping = Config.ALLOW_JUMPING
	}, function(result)
		-- Check if npc is still valid and path is still relevant
		if not npc.Parent or npc:GetAttribute("CurrentPathId") ~= pathId then return end
		
		if targetResource and not targetResource:IsDescendantOf(workspace) then
			releaseClaimedResource(npc)
			npc:SetAttribute("Task", "WaitingForRespawn")
			return
		end
		
		if result.success and result.waypoints then
			setCachedPath(cacheHash, result.waypoints)
			npc:SetAttribute("PathfindingFails", 0)
			
			handlePath(npc, result.waypoints, request.callback)
		else
			handlePathFailure(npc)
		end
	end)
end

local doWander
local doMinerWork
local goHomeAndSleep
local leaveHome

-- reads state first, then decides what to do, then does it
-- keeping reads and writes separate makes this easier to parallelise later
local function processNpcLogic(npc)
	if isSelfManaged(npc) then
		return
	end

	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	-- read everything up front
	local posY = rootPart.Position.Y
	local isAsleep = npc:GetAttribute("IsAsleep")
	local clockTime = Lighting.ClockTime
	local currentTask = npc:GetAttribute("Task")
	local cooldownEnd = npc:GetAttribute("CooldownEndTime") or 0
	local job = npc:GetAttribute("Job")
	local now = os.clock()

	local action = nil

	if posY < Config.VOID_RESCUE_HEIGHT then
		action = "VoidRescue"
	elseif currentTask == "Cooldown" then
		if now > cooldownEnd then
			action = "EndCooldown"
		end
	elseif clockTime >= Config.SLEEP_START_HOUR or clockTime < Config.DAY_START_HOUR then
		if not isAsleep then
			action = "GoSleep"
		end
	elseif isAsleep and clockTime >= Config.DAY_START_HOUR and clockTime < Config.SLEEP_START_HOUR then
		action = "WakeUp"
	elseif
		currentTask == "Walking"
		or currentTask == "Going Home"
		or currentTask == "Pathing Queued"
		or currentTask == "Mining"
		or currentTask == "WaitingForRespawn"
	then
		action = "Busy"
	elseif currentTask == "Idle" then
		if clockTime >= Config.WORK_START_HOUR and clockTime < Config.WORK_END_HOUR then
			if job == "Miner" then
				action = "DoMinerWork"
			elseif job == "Walker" then
				action = "DoWander"
			end
		else
			if job ~= "Police" then
				action = "DoWander"
			end
		end
	end

	-- now actually do the thing
	if action == nil or action == "Busy" then
		return
	elseif action == "VoidRescue" then
		teleportNpcHome(npc)
	elseif action == "EndCooldown" then
		if npc:GetAttribute("NeedsToGoHome") then
			npc:SetAttribute("NeedsToGoHome", nil)
			npc:SetAttribute("Task", "Going Home") -- re-triggers goHomeAndSleep
		else
			npc:SetAttribute("Task", "Idle")
		end
	elseif action == "GoSleep" then
		goHomeAndSleep(npc)
	elseif action == "WakeUp" then
		leaveHome(npc)
	elseif action == "DoMinerWork" then
		doMinerWork(npc)
	elseif action == "DoWander" then
		doWander(npc)
	end
end

-- only runs during work hours, uses tags so we dont loop every npc
-- uses CollectionService + magnitude instead of expensive spatial queries
local function assignMiningJobs()
	for _, npc in ipairs(CollectionService:GetTagged("Miner")) do
		if not npc.Parent then
			continue
		end

		local currentTask = npc:GetAttribute("Task")
		if currentTask == "Idle" or currentTask == "WaitingForRespawn" then
			local root = npc:FindFirstChild("HumanoidRootPart")
			if not root then
				continue
			end

			-- waiting miners camp close to the respawn spot, idle ones search further
			local range = (currentTask == "WaitingForRespawn") and Config.CAMPING_RANGE
				or Config.MAX_RESOURCE_SEARCH_RANGE

			local blacklisted = getObjectValue(npc, "BlacklistedOre")
			local rootPos = root.Position
			local closestRock = nil
			local closestDist = range

			-- Use Spatial Hash Grid to only check rocks in adjacent chunks
			local nearbyRocks = ResourceGrid:QueryRadius(rootPos, range)

			for _, rock in ipairs(nearbyRocks) do
				if not rock.Parent or not rock:IsDescendantOf(workspace) then
					continue
				end

				if rock == blacklisted or getObjectValue(rock, "TargetedBy") then
					continue
				end

				local rockPart = rock:FindFirstChild("HumanoidRootPart")
					or rock.PrimaryPart
					or rock:FindFirstChildWhichIsA("BasePart")
				if not rockPart then
					continue
				end

				local dist = (rockPart.Position - rootPos).Magnitude
				if dist < closestDist then
					closestDist = dist
					closestRock = rock
				end
			end

			if closestRock then
				setObjectValue(closestRock, "TargetedBy", npc)
				setObjectValue(npc, "ClaimedResource", closestRock)
				npc:SetAttribute("Task", "Idle")
			end
		end
	end
end

local function doDepositRoutine(npc)
	local inventory = npc:FindFirstChild("Inventory")
	if not inventory or #inventory:GetChildren() == 0 then
		npc:SetAttribute("Task", "Idle")
		return
	end

	local validShops = {}
	for _, shop in ipairs(CollectionService:GetTagged("Shop")) do
		if shop:IsA("Model") and shop:FindFirstChild("Stock") then
			table.insert(validShops, shop)
		end
	end

	if #validShops > 0 then
		local randomShop = validShops[math.random(1, #validShops)]
		local stockFolder = randomShop.Stock
		for _, item in ipairs(inventory:GetChildren()) do
			item.Parent = stockFolder
		end
	end

	npc:SetAttribute("Task", "Idle")
end

doWander = function(npc)
	if npc:GetAttribute("Task") ~= "Idle" then
		return
	end

	local paymentFolders = CollectionService:GetTagged("PaymentsFolder")
	local paymentsFolder = paymentFolders[1]
	if not paymentsFolder or #paymentsFolder:GetChildren() == 0 then
		return
	end

	local pavementParts = paymentsFolder:GetChildren()
	local randomPavement = pavementParts[math.random(1, #pavementParts)]
	local jitteredTarget = getJitteredPosition(randomPavement.Position, 8)
	requestWalkTo(npc, jitteredTarget)
end

doMinerWork = function(npc)
	local closestResource = getObjectValue(npc, "ClaimedResource")

	if not (closestResource and closestResource.Parent) then
		if npc:GetAttribute("Task") == "WaitingForRespawn" then
			return
		end

		npc:SetAttribute("Task", "Idle")
		if ejectFromCave(npc) then
			return
		end
		-- no rock found, wait a bit before searching again
		npc:SetAttribute("Task", "Cooldown")
		npc:SetAttribute("CooldownEndTime", os.clock() + Config.RESOURCE_SEARCH_COOLDOWN)
		return
	end

	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	local distToRock = (rootPart.Position - closestResource.Position).Magnitude

	-- rock might be underground, check if they need to go through a cave entrance
	if distToRock > 20 then
		local caveEntrances = workspace:FindFirstChild("CaveEntrances")
		if caveEntrances then
			for _, cave in ipairs(caveEntrances:GetChildren()) do
				local p1 = cave:FindFirstChild("Point1")
				if p1 then
					local distToInside = (closestResource.Position - p1.Position).Magnitude
					if distToInside <= Config.CAVE_DETECTION_RANGE then
						local npcDistToInside = (rootPart.Position - p1.Position).Magnitude
						local heightDiff = rootPart.Position.Y - p1.Position.Y
						if npcDistToInside > Config.CAVE_DETECTION_RANGE or heightDiff > 40 then
							-- walk to the outside entrance then teleport in
							requestWalkTo(npc, cave:FindFirstChild("Point2").Position, function()
								if npc and npc.Parent then
									npc:PivotTo(p1.CFrame + Vector3.new(0, 5, 0))
									npc:SetAttribute("Task", "Idle")
								end
							end)
							return
						end
					end
				end
			end
		end
	end

	local function onArrivedAtMine()
		if not closestResource or not closestResource.Parent or not closestResource:IsDescendantOf(workspace) then
			releaseClaimedResource(npc)
			npc:SetAttribute("Task", "WaitingForRespawn")
			stopMiningAnimation(npc)
			return
		end

		npc:SetAttribute("Task", "Mining")
		local tool = equipMinerTool(npc)

		-- watch for the rock getting destroyed mid-swing
		local destructionConnection
		destructionConnection = closestResource.AncestryChanged:Connect(function()
			if not closestResource:IsDescendantOf(workspace) then
				npc:SetAttribute("Task", "WaitingForRespawn")
				stopMiningAnimation(npc)
				if destructionConnection then
					destructionConnection:Disconnect()
				end
			end
		end)

		-- face the rock
		local lookPos =
			Vector3.new(closestResource.Position.X, npc.HumanoidRootPart.Position.Y, closestResource.Position.Z)
		npc.HumanoidRootPart.CFrame = CFrame.lookAt(npc.HumanoidRootPart.Position, lookPos)

		-- swing loop, server sets AnimState and client plays the animation
		while npc:GetAttribute("Task") == "Mining" and closestResource:IsDescendantOf(workspace) do
			if Lighting.ClockTime >= Config.WORK_END_HOUR then
				npc:SetAttribute("Task", "Idle")
				break
			end

			if tool then
				if tool:GetAttribute("Debounce") == false then
					tool:SetAttribute("Debounce", true)
					setAnimState(npc, "MineSwing")
					task.wait(Config.MINING_SWING_DURATION)
					tool:SetAttribute("Debounce", false)
				else
					task.wait(0.2)
				end
			else
				task.wait(0.5)
			end
		end

		if destructionConnection then
			destructionConnection:Disconnect()
		end
		stopMiningAnimation(npc)
	end

	-- jitter so multiple miners on the same rock dont all stand in the same spot
	local jitteredTarget = getJitteredPosition(closestResource.Position, 4)
	requestWalkTo(npc, jitteredTarget, onArrivedAtMine)
end

goHomeAndSleep = function(npc)
	releaseClaimedResource(npc)
	unequipMinerTool(npc)

	local currentTask = npc:GetAttribute("Task")
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		return
	end

	-- already inside, nothing to do
	if npc:GetAttribute("IsAsleep") then
		if currentTask ~= "Going Home" then
			npc:SetAttribute("Task", "Idle")
		end
		return
	end

	-- dont spam go home attempts
	if currentTask == "Going Home" or currentTask == "Cooldown" then
		local lastAttempt = npc:GetAttribute("LastGoHomeAttempt") or 0
		if os.clock() - lastAttempt < Config.GO_HOME_RETRY_TIME then
			return
		end
	end

	npc:SetAttribute("Task", "Going Home")
	npc:SetAttribute("LastGoHomeAttempt", os.clock())

	local homeValue = npc:FindFirstChild("Homeval")
	if not (homeValue and homeValue.Value) then
		npc:SetAttribute("Task", "Idle")
		return
	end

	local house = homeValue.Value
	local door = house:FindFirstChild("Door")
	if door then
		requestWalkTo(npc, door.Position, function()
			if npc and npc.Parent and rootPart then
				local insidePosition = door.CFrame * CFrame.new(6, 0, 0)
				npc:PivotTo(insidePosition)
				npc:SetAttribute("IsAsleep", true)
				npc:SetAttribute("Task", "Idle")
			end
		end)
	else
		npc:SetAttribute("Task", "Idle")
	end
end

leaveHome = function(npc)
	local rootPart = npc:FindFirstChild("HumanoidRootPart")
	if not rootPart or not npc:GetAttribute("IsAsleep") then
		return
	end

	local homeValue = npc:FindFirstChild("Homeval")
	if not (homeValue and homeValue.Value) then
		return
	end

	local house = homeValue.Value
	local door = house:FindFirstChild("Door")
	npc:SetAttribute("IsAsleep", false)

	if door then
		local offset = -door.CFrame.LookVector * math.random(3, 6)
		local exitCFrame = door.CFrame + offset
		npc:PivotTo(exitCFrame)
	end
	npc:SetAttribute("Task", "Idle")
end

local function populateHouses(npcsFolder)
	local npcTemplates = ReplicatedStorage:FindFirstChild("Npc's")
	if not npcTemplates then
		return
	end

	local residents, walkers, adventurerTemplates = {}, {}, {}
	for _, v in ipairs(npcTemplates:GetChildren()) do
		if v.Name == "Walker" then
			table.insert(walkers, v)
		elseif isSelfManaged(v) then
			table.insert(adventurerTemplates, v)
		else
			table.insert(residents, v)
		end
	end

	if #residents == 0 then
		return
	end

	local houses = CollectionService:GetTagged("House")
	local populatedCount = 0

	for _, house in ipairs(houses) do
		if house:HasTag("Populated") then
			continue
		end
		house:AddTag("Populated")

		-- yield every few houses so we dont freeze the server during startup
		if populatedCount % Config.HOUSES_PER_FRAME_GEN == 0 then
			task.wait()
		end
		populatedCount += 1

		local residentCount = house:GetAttribute("Residents") or 1
		

		for i = 1, residentCount do
			local isWalker = math.random(1, 3) ~= 3
			local tmpl = isWalker and walkers[math.random(#walkers)] or residents[math.random(#residents)]

			if tmpl then
				local newNpc = tmpl:Clone()
				newNpc.Parent = npcsFolder
				
				setObjectValue(newNpc, "Homeval", house)
				optimizeHumanoid(newNpc)
				newNpc:SetAttribute("Task", "Idle")

				-- stagger their first wander so they dont all path at once on startup
				task.delay(math.random(1, 5), function()
					if newNpc.Parent then
						doWander(newNpc)
					end
				end)
			end
		end

		-- spawn an adventurer at this house occasionally
		-- they manage themselves via Basic.Lua, we just give them a home position
		if #adventurerTemplates > 0 and math.random(1, 5) == 1 then
			local tmpl = adventurerTemplates[math.random(#adventurerTemplates)]
			local adv = tmpl:Clone()
			adv.Parent = npcsFolder
			setObjectValue(adv, "Homeval", house)

			-- place at the door so Basic.Lua picks up the right startingpos
			local door = house:FindFirstChild("Door")
			if door then
				local spawnCFrame = door.CFrame * CFrame.new(-6, 2, -6)
				adv:PivotTo(spawnCFrame)
			end

			optimizeHumanoid(adv)

			-- still needs the tag so npchieder.lua does its visual stuff
			if not adv:HasTag("Npc") then
				adv:AddTag("Npc")
			end
		end
	end
end

for _, npcsFolder in ipairs(game.Workspace:GetDescendants()) do
	if npcsFolder.Name == "Npcs" and npcsFolder:IsA("Folder") then
		print("[NPC] Initialising server-authoritative NPC controller…")

		task.spawn(function()
			populateHouses(npcsFolder)
		end)

		-- slowly moves gathered items to shops
		task.spawn(function()
			while task.wait(Config.ECONOMY_LOOP_WAIT) do
				for _, npc in ipairs(npcsFolder:GetChildren()) do
					if isSelfManaged(npc) then
						continue
					end
					local items = npc:FindFirstChild("Items")
					if items then
						for _, item in ipairs(items:GetChildren()) do
							item.Parent = npcsFolder.Parent.Economy
						end
					end
				end
			end
		end)

		-- assign rocks to idle miners, only runs during work hours
		task.spawn(function()
			while task.wait(Config.JOB_DISPATCH_WAIT) do
				if Lighting.ClockTime >= Config.WORK_START_HOUR and Lighting.ClockTime < Config.WORK_END_HOUR then
					pcall(assignMiningJobs)
				end
			end
		end)

		-- drain the queue, max 5 per tick so we dont stall
		task.spawn(function()
			while true do
				task.wait(0.1)
				local processed = 0
				while #pathfindingQueue > 0 and processed < 5 do
					local request = table.remove(pathfindingQueue, 1)
					if request.npc and request.npc.Parent then
						processPathfindingRequest(request)
					end
					processed += 1
				end
			end
		end)

		-- main brain, time-budgeted so it uses available cpu without dropping frames
		task.spawn(function()
			local budget = Config.BRAIN_TIME_BUDGET
			while true do
				local children = npcsFolder:GetChildren()
				local frameStart = os.clock()

				for _, npc in ipairs(children) do
					if npc:IsA("Model") then
						local ok, err = pcall(processNpcLogic, npc)
						if not ok then
							warn("[NPC] Error [" .. npc.Name .. "]: " .. tostring(err))
						end
					end
					-- yield once we hit the time budget, then resume next frame
					if os.clock() - frameStart > budget then
						task.wait()
						frameStart = os.clock()
					end
				end

				task.wait(Config.MAIN_LOOP_WAIT +0.2)
			end
		end)

		break -- only care about the first Npcs folder
	end
end
