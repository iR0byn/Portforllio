-- Re-parse trigger
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SlimeFolder = script.Parent
--// Services
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AnalyticsService = game:GetService("AnalyticsService")

-- Player cache
local PlayerCache = {}
task.spawn(function()
	while task.wait(2) do
		table.clear(PlayerCache)
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			if char then
				local hrp = char:FindFirstChild("HumanoidRootPart")
				local hum = char:FindFirstChild("Humanoid")
				if hrp and hum and hum.Health > 0 then
					local canDmg = hum:FindFirstChild("cantakedamage")
					table.insert(PlayerCache, {
						Character = char,
						Position = hrp.Position,
						Humanoid = hum,
						RootPart = hrp,
						CanTakeDamage = canDmg and canDmg.Value or false,
					})
				end
			end
		end
	end
end)
--// Assets
local VFX_FOLDER = ReplicatedStorage:WaitForChild("vfx")
local DAMAGE_INDICATOR_TEMPLATE = VFX_FOLDER:WaitForChild("Damage")
local HIT_ANIMATION_FOLDER = ReplicatedStorage:WaitForChild("Character"):WaitForChild("Animations"):WaitForChild("hit")

-- Settings
local CONFIG = {
	ForwardForce = 40, -- Wander speed

	-- Attack Settings
	AttackRange = 35, -- Distance to spot an enemy
	DashForce = 200, -- Speed of the dash attack
	AttackJumpForce = 40, -- Height of the jump before dashing
	AttackDamage = 7, -- Base Damage dealt
	HealthBase = 100, -- Base Health

	-- Scaling Settings
	HealthPerLevel = 10,
	DamagePerLevel = 1.5,
	SpeedPerLevel = 0.5,

	JumpCooldown = 2,
	AirTime = 0.5, -- Max seconds to wait for a landed slime (safety timeout)
	LandCheckInterval = 0.05, -- How often to poll Y velocity to detect landing
	MaxJumpHeight = 7, -- Max studs a slime can rise above its ground position during wander
	RespawnTime = 60,
	LOD_Distance = 150, -- Animation range limit
	LOD_SLEEP_DISTANCE = 450, -- Range to skip logic
	ROAM_RADIUS = 150, -- Max studs a slime can wander from its spawn point
}

-- Derive velocity from desired jump height: v = sqrt(2 * g * h)
local GRAVITY = workspace.Gravity or 196.2
CONFIG.UpwardForce = math.sqrt(3.5 * GRAVITY * CONFIG.MaxJumpHeight)
CONFIG.DownForce = -CONFIG.UpwardForce * 1.2 -- Slam down at same speed to guarantee landing
CONFIG.AttackJumpForce = CONFIG.UpwardForce * 1.2 -- Slam down at same speed to guarantee landing

-- Velocity helpers
local function applyVelocity(part, velocity, duration)
	part.AssemblyLinearVelocity = velocity

	local bv = part:FindFirstChild("SlimeBodyVelocity")
	if not bv then
		return
	end

	bv.Velocity = velocity
	bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)

	local currentTick = tick()
	part:SetAttribute("LVTick", currentTick)
	task.delay(duration, function()
		if part.Parent and part:GetAttribute("LVTick") == currentTick then
			bv.MaxForce = Vector3.zero
		end
	end)
end

local function stopVelocity(part)
	local bv = part:FindFirstChild("SlimeBodyVelocity")
	if not bv then
		return
	end

	bv.Velocity = Vector3.zero
	bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)

	local currentTick = tick()
	part:SetAttribute("LVTick", currentTick)
	task.delay(0.2, function()
		if part.Parent and part:GetAttribute("LVTick") == currentTick then
			bv.MaxForce = Vector3.zero
		end
	end)
end

local squashInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local popInfo = TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local deathInfo = TweenInfo.new(1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Shared highlight for hits
local sharedHitHighlight = Instance.new("Highlight")
sharedHitHighlight.FillColor = Color3.new(1, 0, 0.0156863)

-- Template setup
local existingSlime = SlimeFolder:FindFirstChild("Slimeb") or SlimeFolder:FindFirstChild("Slime")

if not existingSlime then
	warn("No 'Slime' found in folder to use as template!")
	return
end

local MasterTemplate = existingSlime:Clone()
if MasterTemplate.PrimaryPart then
	MasterTemplate.PrimaryPart.AssemblyLinearVelocity = Vector3.zero
end

-- findNearestTarget removed in favor of global PlayerCache

local function runSlimeLogic(slimeModel, spawnCFrame)
	task.spawn(function()
		-- 1. Validation & Part Caching
		local rootPart = slimeModel.PrimaryPart
			or slimeModel:FindFirstChild("HumanoidRootPart")
			or slimeModel:FindFirstChild("Inside")

		if rootPart:IsA("BasePart") then
			rootPart:SetNetworkOwner(nil)
		end

		local directionPart = slimeModel:WaitForChild("Glidedirec", 5)
		local inside = slimeModel:FindFirstChild("Inside")
		local outside = slimeModel:FindFirstChild("Outside")
		local humanoid = slimeModel:FindFirstChild("Humanoid")

		if not (rootPart and directionPart and inside and outside) then
			if slimeModel.Parent then
				slimeModel:Destroy()
			end
			return
		end

		-- Reuse OverlapParams
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Exclude
		overlapParams.FilterDescendantsInstances = { slimeModel }

		-- Use shared highlight
		local hitHighlight = sharedHitHighlight

		local level = slimeModel:GetAttribute("Level") or 1

		-- Calculate stats
		local maxHealth = CONFIG.HealthBase + (level * CONFIG.HealthPerLevel)
		local damage = CONFIG.AttackDamage + (level * CONFIG.DamagePerLevel)
		local speedMod = (level * CONFIG.SpeedPerLevel)

		local currentForwardSpeed = CONFIG.ForwardForce + speedMod
		local currentDashSpeed = CONFIG.DashForce + speedMod
		local currentAttackJumpSpeed = CONFIG.AttackJumpForce + speedMod

		if humanoid then
			humanoid.MaxHealth = maxHealth
			humanoid.Health = maxHealth
		end

		-- Sound setup
		local function setupSound(name)
			local targetPart = slimeModel.PrimaryPart or rootPart
			local snd = slimeModel:FindFirstChild(name) or targetPart:FindFirstChild(name)

			if snd then
				snd.Parent = targetPart
				if snd.SoundId == "" or snd.SoundId == "rbxassetid://" then
					warn("Slime Sound '" .. name .. "' has no SoundId!")
				end
				return snd
			end
			return nil
		end

		local sounds = {
			Jump = setupSound("jump"),
			Land = setupSound("land"),
			Die = setupSound("die"),
			Hit = setupSound("Hit"),
			Damage = setupSound("Damage"),
		}

		local function playSound(name)
			if sounds[name] then
				sounds[name]:Play()
			end
		end

		local insideBase = inside.Size
		local outsideBase = outside.Size
		local isDead = false

		-- Physics Setup
		rootPart.Anchored = false
		-- Physics properties updated for combat
		rootPart.CustomPhysicalProperties = PhysicalProperties.new(
			0.5, -- Density
			0, -- Friction
			0.5, -- Elasticity
			1, -- FrictionWeight
			0.5 -- ElasticityWeight
		)

		if not rootPart:FindFirstChild("SlimeBodyVelocity") then
			local bv = Instance.new("BodyVelocity")
			bv.Name = "SlimeBodyVelocity"
			bv.Velocity = Vector3.zero
			bv.MaxForce = Vector3.zero -- Disabled by default
			bv.P = 1e6 -- High power for responsive movement
			bv.Parent = rootPart
		end

		if not rootPart:FindFirstChild("AntiFlipGyro") then
			local attach = Instance.new("Attachment")
			attach.Name = "GyroAttachment"
			attach.Axis = Vector3.new(0, 1, 0)
			attach.Parent = rootPart

			local align = Instance.new("AlignOrientation")
			align.Name = "AntiFlipGyro"
			align.Mode = Enum.OrientationAlignmentMode.OneAttachment
			align.Attachment0 = attach
			align.AlignType = Enum.AlignType.PrimaryAxisParallel
			align.PrimaryAxis = Vector3.new(0, 1, 0)
			align.RigidityEnabled = true
			align.MaxTorque = 1000000
			align.Responsiveness = 200
			align.Parent = rootPart
		end

		-- Death handling
		local function handleDeath()
			if isDead then
				return
			end
			isDead = true
			local creatorTag = humanoid:FindFirstChild("creator")

			if creatorTag then
				if creatorTag.Value and creatorTag.Value:IsA("Player") then
					local player = creatorTag.Value

					-- Navigate the player data structure safely
					local pdata = player:FindFirstChild("pdata")
					if not pdata then
						warn("❌ Could not find 'pdata' folder inside player:", player.Name)
						return
					end

					local statsFolder = pdata:FindFirstChild("stats")
					if not statsFolder then
						warn("❌ Could not find 'stats' folder inside pdata.")
						return
					end

					local expValueObject = statsFolder:FindFirstChild("exp")

					if expValueObject then
						-- Get EXP from attribute, default to 0 if missing
						local expReward = slimeModel:GetAttribute("exp")

						if not expReward then
							warn("⚠️ slimeModel '" .. slimeModel.Name .. "' has no 'exp' attribute! Giving 0 exp.")
							expReward = 0
						end

						expValueObject.Value += expReward
					else
						warn("❌ Could not find 'exp' ValueObject inside stats.")
					end
				end
			end

			playSound("Die")

			stopVelocity(rootPart)
			inside.Anchored = true
			outside.Anchored = true

			for _, joint in pairs(inside:GetJoints()) do
				joint:Destroy()
			end
			for _, joint in pairs(outside:GetJoints()) do
				joint:Destroy()
			end

			local floorOffsetInside = insideBase.Y / 2
			local floorOffsetOutside = outsideBase.Y / 2

			TweenService:Create(inside, deathInfo, {
				Size = Vector3.new(insideBase.X, 0, insideBase.Z),
				CFrame = inside.CFrame * CFrame.new(0, -floorOffsetInside, 0),
			}):Play()

			TweenService:Create(outside, deathInfo, {
				Size = Vector3.new(outsideBase.X, 0, outsideBase.Z),
				CFrame = outside.CFrame * CFrame.new(0, -floorOffsetOutside, 0),
			}):Play()

			-- Respawn logic
			task.delay(5, function()
				task.wait(0.25)
				if slimeModel then
					slimeModel:Destroy()
				end
			end)

			task.delay(CONFIG.RespawnTime, function()
				local newSlime = MasterTemplate:Clone()
				newSlime.Name = "Slime"
				newSlime:SetPrimaryPartCFrame(spawnCFrame)
				newSlime.Parent = SlimeFolder
				newSlime:SetAttribute("Level", level)
				if slimeModel then
					newSlime:ScaleTo(slimeModel:GetScale())
				end
				newSlime:SetAttribute("exp", CONFIG.AttackDamage + (level * CONFIG.DamagePerLevel))

				runSlimeLogic(newSlime, spawnCFrame)
			end)
		end

		if humanoid then
			humanoid.Died:Connect(handleDeath)

			local lastHealth = humanoid.Health
			humanoid.HealthChanged:Connect(function(health)
				if health < lastHealth and health > 0 then
					playSound("Damage")
				end
				lastHealth = health
				if health <= 0 then
					handleDeath()
				end
			end)
		end

		-- Pre-calc tweens
		local outSquash =
			TweenService:Create(outside, squashInfo, { Size = Vector3.new(outsideBase.X, 0.2, outsideBase.Z) })
		local inSquash =
			TweenService:Create(inside, squashInfo, { Size = Vector3.new(insideBase.X, 0.2, insideBase.Z) })
		local inPop = TweenService:Create(inside, popInfo, { Size = insideBase })
		local outPop = TweenService:Create(outside, popInfo, { Size = outsideBase })

		task.wait(math.random(1, 20) / 10)

		-- 2. The Loop
		while slimeModel.Parent do
			if isDead then
				break
			end
			task.wait(CONFIG.JumpCooldown + math.random() * 0.8)
			if not (rootPart.Parent and directionPart.Parent and inside.Parent and outside.Parent) then
				break
			end
			if isDead then
				break
			end

			-- Distance checks
			local shouldAnimate = false
			local target = nil
			local cantakedamage = false
			local minDistance = CONFIG.AttackRange
			local absoluteMinDistance = math.huge
			local myPos = rootPart.Position

			for _, pData in ipairs(PlayerCache) do
				local dist = (pData.Position - myPos).Magnitude
				if dist < absoluteMinDistance then
					absoluteMinDistance = dist
				end

				if dist < CONFIG.LOD_Distance then
					shouldAnimate = true
				end
				if dist < minDistance then
					minDistance = dist
					target = pData.RootPart
					cantakedamage = pData.CanTakeDamage
				end
			end

			-- Skip for distant slimes
			if absoluteMinDistance > CONFIG.LOD_SLEEP_DISTANCE then
				task.wait(3) -- sleep longer when nobody is remotely close
				continue
			end

			local isAttacking = (target ~= nil)
			if isAttacking then
				isAttacking = cantakedamage
			end

			if shouldAnimate then
				if isAttacking then
					rootPart.CFrame = CFrame.lookAt(
						rootPart.Position,
						Vector3.new(target.Position.X, rootPart.Position.Y, target.Position.Z)
					)
				end

				inSquash:Play()
				outSquash:Play()
				task.wait(0.25)

				if isDead then
					break
				end

				inPop:Play()
				outPop:Play()
				task.wait(0.05)
			else
				task.wait(0.55)
			end

			if isDead then
				break
			end

			local groundY = rootPart.Position.Y

			if absoluteMinDistance > (CONFIG.LOD_Distance * 3) then
				stopVelocity(rootPart)
				if rootPart.Position.Y > groundY + 1 then
					applyVelocity(rootPart, Vector3.new(0, CONFIG.DownForce, 0), 0.5)
				end
			else
				if rootPart.Parent.Humanoid.canMove.Value == true then
					if
						isAttacking
						and target
						and target.Parent
						and rootPart.Parent.Humanoid.canattack.Value == true
					then
						playSound("Jump")
						applyVelocity(rootPart, Vector3.new(0, currentAttackJumpSpeed, 0), 0.2)
						task.wait(0.2)

						if isDead then
							break
						end

						-- Dash Towards Enemy
						if target and target.Parent then
							local dashDirection = (target.Position - rootPart.Position).Unit
							applyVelocity(rootPart, dashDirection * currentDashSpeed, 0.4)

							local hasHit = false
							local dashDuration = 0.4
							local dashEnd = tick() + dashDuration

							task.spawn(function()
								while tick() < dashEnd and not isDead and rootPart.Parent and not hasHit do
									task.wait(0.1)
									local hits = workspace:GetPartBoundsInRadius(rootPart.Position, 5, overlapParams)
									for _, hit in ipairs(hits) do
										local hitModel = hit.Parent
										if hitModel and hitModel.Name ~= "Slime" and hitModel.Name ~= "Slimeb" then
											local hum = hitModel:FindFirstChild("Humanoid")
											if
												hum
												and rootPart.Parent.Humanoid.canMove.Value == true
												and rootPart.Parent.Humanoid.canattack.Value == true
											then
												local canDmg = hum:FindFirstChild("cantakedamage")
												if canDmg and canDmg.Value == true then
													playSound("Hit")

													local rawDamage = damage
													local damageCap = hum.MaxHealth * 0.4
													local finalDamage = math.min(rawDamage, damageCap)

													local targetHumanoid = hum
													local blockCounter = targetHumanoid:GetAttribute("blockcounter")

													if blockCounter then
													else
														targetHumanoid:SetAttribute("blockcounter", 0)
													end

													local isBlockBroken = (
														hum:GetAttribute("Blocking")
														and (blockCounter >= 3 or math.random(1, 7) == 1)
													)

													if isBlockBroken then
														targetHumanoid:SetAttribute("blockcounter", 0)

														targetHumanoid:SetAttribute("Blocking", false)
													end

													if hum:GetAttribute("Blocking") then
														local damagenumber = DAMAGE_INDICATOR_TEMPLATE:Clone()
														damagenumber.TextLabel.TextColor3 = Color3.new(1, 1, 1)

														damagenumber.TextLabel.Text = "Blocked"
														damagenumber.Parent = hitModel:FindFirstChild("Torso")
															or hitModel:FindFirstChild("HumanoidRootPart")
														damagenumber.Script.Enabled = true
														if blockCounter then
															targetHumanoid:SetAttribute(
																"blockcounter",
																blockCounter + 1
															)
														else
															targetHumanoid:SetAttribute("blockcounter", 1)
														end

														hitHighlight.FillColor = Color3.new(1, 1, 1)
														if humanoid.Health >= finalDamage then
															finalDamage = 0
														else
														end
													else
														local damagenumber = DAMAGE_INDICATOR_TEMPLATE:Clone()
														damagenumber.TextLabel.TextColor3 = Color3.new(1, 0, 0)
														damagenumber.TextLabel.Text = "-" .. tostring(finalDamage)
														damagenumber.Parent = hitModel:FindFirstChild("Torso")
															or hitModel:FindFirstChild("HumanoidRootPart")
														damagenumber.Script.Enabled = true

														hitHighlight.FillColor = Color3.new(1, 0.12549, 0.12549)
													end

													hum:TakeDamage(finalDamage)

													hitHighlight.Parent = hitModel
													task.delay(0.5, function()
														hitHighlight.Parent = nil
													end)

													hasHit = true
													break
												end
											end
										end
									end
								end
							end)
						end

						task.wait(0.3)
						if not isDead and rootPart.Parent then
							applyVelocity(rootPart, Vector3.new(0, CONFIG.DownForce, 0), 0.5)
						end
					else
						local spawnPos = spawnCFrame.Position
						local distFromSpawn = (rootPart.Position - spawnPos).Magnitude
						local flatDir

						if distFromSpawn > CONFIG.ROAM_RADIUS then
							local toHome = spawnPos - rootPart.Position
							flatDir = Vector3.new(toHome.X, 0, toHome.Z).Unit
						else
							local directionVector = (directionPart.Position - rootPart.Position).Unit
							flatDir = Vector3.new(directionVector.X, 0, directionVector.Z).Unit
						end

						playSound("Jump")
						groundY = rootPart.Position.Y

						local jumpVelocity = (flatDir * currentForwardSpeed) + Vector3.new(0, CONFIG.UpwardForce, 0)
						applyVelocity(rootPart, jumpVelocity, 0.15)

						local airTimer = 0
						local airIterations = 0
						repeat
							task.wait(0.1) -- PERF: Reduced from 0.05
							airTimer = airTimer + 0.1
							airIterations = airIterations + 1

							if rootPart.Position.Y > groundY + CONFIG.MaxJumpHeight then
								applyVelocity(rootPart, Vector3.new(0, CONFIG.DownForce, 0), 0.5)
								break
							end
						until rootPart.AssemblyLinearVelocity.Y <= 0
							or airTimer >= CONFIG.AirTime * 2
							or isDead
							or airIterations >= 20
					end
				end
			end

			-- Brake (Landing) — FORCE the slime downward so it can never hang in mid-air
			if not isDead then
				playSound("Land")
				-- Stop all existing impulses and force downward if still airborne
				stopVelocity(rootPart)
				if rootPart.Position.Y > groundY + 1 then
					applyVelocity(rootPart, Vector3.new(0, CONFIG.DownForce, 0), 0.5)
				end
			end
		end
	end)
end

-- Level generation
local function getWeightedLevel()
	local roll = math.random(1, 100)

	-- 60% Chance: Level 1 - 15 (Common)
	if roll <= 60 then
		return math.random(1, 15)
		-- 25% Chance: Level 16 - 40 (Uncommon)
	elseif roll <= 85 then
		return math.random(16, 40)
		-- 10% Chance: Level 41 - 70 (Rare)
	elseif roll <= 95 then
		return math.random(41, 70)
		-- 5% Chance: Level 71 - 100 (Legendary)
	else
		return math.random(71, 100)
	end
end

-- Update quests
local function updateQuestsForPlayer(player, levell)
	if not player then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		return
	end

	local questMenu = playerGui:WaitForChild("Quest Menu", 5)
	if questMenu then
		local scrollingFrame = questMenu:WaitForChild("Get"):WaitForChild("Quests"):WaitForChild("ScrollingFrame")
		local questTemp = questMenu.Get.Quests:FindFirstChild("Temp")

		if scrollingFrame and questTemp then
			local questclone = questTemp:Clone()
			questclone.Name = "Kill 10 Slimes"
			questclone.Title.Text = "Kill 10 Slimes"
			questclone.Parent = scrollingFrame
			questclone.Visible = true
			questclone:SetAttribute("LVL", levell)
			questclone.Rec.Text = "LvL " .. tostring(levell)
		end
	end
end

-- 1. Get raw children
local rawChildren = SlimeFolder:GetChildren()
local spawnsToSort = {}

-- 2. Filter out valid slime spawns
for _, child in pairs(rawChildren) do
	if child.Name == "Slime" or child.Name == "Slimeb" then
		table.insert(spawnsToSort, child)
	end
end

-- 3. Sort them physically by distance from the world center (0,0,0)
-- This ensures that slimes physically next to each other are processed in order
table.sort(spawnsToSort, function(a, b)
	local posA = a.PrimaryPart and a.PrimaryPart.Position
		or (a:FindFirstChild("Inside") and a.Inside.Position)
		or Vector3.zero
	local posB = b.PrimaryPart and b.PrimaryPart.Position
		or (b:FindFirstChild("Inside") and b.Inside.Position)
		or Vector3.zero

	-- We compare the Magnitude (distance) from the origin
	return (posA - Vector3.zero).Magnitude < (posB - Vector3.zero).Magnitude
end)

task.wait(2)
local cyclle = 10
local count = 0
local level = getWeightedLevel()

-- 4. Iterate through the SORTED list
for i, child in ipairs(spawnsToSort) do
	task.spawn(function()
		task.wait((i - 1) * 0.05)

		if not child.Parent then
			return
		end -- may have been destroyed during wait

		local spawnCFrame
		if child.PrimaryPart then
			spawnCFrame = child.PrimaryPart.CFrame
		elseif child:FindFirstChild("Inside") then
			spawnCFrame = child.Inside.CFrame
		else
			spawnCFrame = CFrame.new()
		end

		local freshSlime = MasterTemplate:Clone()
		freshSlime:ScaleTo(child:GetScale())
		freshSlime.Name = "Slime"

		freshSlime:SetAttribute("Level", level)
		count += 1

		freshSlime:SetPrimaryPartCFrame(spawnCFrame)
		freshSlime.Parent = SlimeFolder

		freshSlime:SetAttribute("exp", CONFIG.AttackDamage + (level * CONFIG.DamagePerLevel))
		child:Destroy()
		runSlimeLogic(freshSlime, spawnCFrame)

		if count >= cyclle then
			-- Update immediately for current players
			for _, player in ipairs(game.Players:GetPlayers()) do
				task.spawn(function()
					updateQuestsForPlayer(player, level)
				end)
			end

			count = 0
			level = getWeightedLevel()
		end
	end)
end

-- Player connection logic

local function onPlayerAdded(player)
	-- Listen for CharacterAdded on this specific player
	player.CharacterAdded:Connect(function(character)
		print("adding slime quests for player since they resepawned")

		-- Safety check for UISTATE
		local uistate = player:FindFirstChild("UISTATE")
		if uistate then
			uistate.Value = 0
		end
		task.wait(3)
		-- Update quests with the CURRENT level (whatever the loop finished with)
		updateQuestsForPlayer(player, level)
	end)
end

-- 1. Connect for NEW players joining later
game.Players.PlayerAdded:Connect(onPlayerAdded)

-- 2. Connect for players ALREADY in the game (like you in Studio)
for _, player in ipairs(game.Players:GetPlayers()) do
	task.spawn(function()
		onPlayerAdded(player)
	end)
end
