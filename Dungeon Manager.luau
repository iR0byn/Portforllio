-- Dungeon Procedural Generation Script

local dungeon = game.Workspace.Dungeon
local floors = dungeon.Floors
local halllenght = 33
local variation = 2
local prevfloor = nil
local floorcount = 100
local width = 15
local floordistancee = 100

-- Cache the pieces folder
local DungeonPieces = game.ReplicatedStorage:WaitForChild("Dungeon Peices")

-- Cache piece templates
local PieceTemplates = {}
for _, piece in ipairs(DungeonPieces:GetChildren()) do
	PieceTemplates[piece.Name] = piece
end

-- Helper to get a cached piece template
local function getPieceTemplate(name)
	return PieceTemplates[name]
end

-- Clone the base floor template into ServerStorage
local base = floors:FindFirstChild("Floor 1"):Clone()
base.Parent = game.ServerStorage

for i = 1, floorcount do
	local floor = floors:FindFirstChild("Floor " .. i)

	if floor then
		print("Found existing floor: " .. floor.Name)
	elseif prevfloor then
		print("Cloning to create Floor " .. i)
		local clone = base:Clone()
		clone.Parent = floors
		clone.Name = "Floor " .. i
		floor = clone

		floor:PivotTo(CFrame.new(base.Mid.Position.X, base.Mid.Position.Y - (i * floordistancee), base.Mid.Position.Z))
	else
		warn("Could not find or create Floor " .. i .. ". Make sure 'Floor 1' exists as a template.")
		continue
	end

	if floor and i % 10 ~= 0 then
		local mid = floor:FindFirstChild("Mid")
		local Exit = floor:FindFirstChild("Exit")
		local Entrance = floor:FindFirstChild("Entrance")
		local nodesFolder = floor:FindFirstChild("Nodes")

		if not (mid and Exit and Entrance and nodesFolder) then
			warn(
				"Warning: Missing Mid, Exit, Entrance, or Nodes folder in "
					.. floor.Name
					.. ". Skipping processing for this floor."
			)
			prevfloor = floor
			continue
		end

		local distance = Entrance.Position.Z - Exit.Position.Z

		-- Snap Exit Z position to be a multiple of halllenght away from Entrance
		Exit.Position = Vector3.new(
			Entrance.Position.X,
			Entrance.Position.Y,
			Entrance.Position.Z - math.round(distance / halllenght) * halllenght
		)

		distance = Entrance.Position.Z - Exit.Position.Z
		mid.Position = Entrance.Position:Lerp(Exit.Position, 0.5)

		local numbernodes = math.abs(distance) / halllenght

		-- Entrance position cache
		local entranceX = Entrance.Position.X
		local entranceY = Entrance.Position.Y
		local entranceZ = Entrance.Position.Z

		-- Loop 1: Create all the node parts
		for nodeIdx = 0, numbernodes do
			local node = mid:Clone()
			node.Name = "node" .. nodeIdx
			node.Parent = nodesFolder
			node.Position = Vector3.new(entranceX, entranceY, entranceZ - (nodeIdx * halllenght))
			node:SetAttribute("index", nodeIdx)

			-- Create horizontal nodes for this row
			local nodeX = node.Position.X
			local nodeY = node.Position.Y
			local nodeZ = node.Position.Z

			for j = 0, width do
				local node1 = mid:Clone()
				node1.Name = "node" .. j
				node1.Parent = node
				node1.Position = Vector3.new(nodeX - (j * halllenght), nodeY, nodeZ)
				node1:SetAttribute("index", j)

				if j ~= 0 then
					local node2 = mid:Clone()
					node2.Name = "node" .. tostring(-1 * j)
					node2.Parent = node
					node2.Position = Vector3.new(nodeX + (j * halllenght), nodeY, nodeZ)
					node2:SetAttribute("index", -1 * j)
				end
			end

			-- Yield every few rows to prevent frame drops
			if nodeIdx % 4 == 0 then
				task.wait()
			end

			if nodeIdx % 4 == 0 then
				if nodeIdx == 4 then
					floor.Room1:PivotTo(
						CFrame.new(
							node.CFrame.Position.X,
							floor.Room1.PrimaryPart.CFrame.Position.Y,
							node.CFrame.Position.Z
						)
					)
				else
					local room = floor.Room1:Clone()
					room.Parent = floor
					room:PivotTo(
						CFrame.new(node.CFrame.Position.X, room.PrimaryPart.CFrame.Position.Y, node.CFrame.Position.Z)
					)
				end
			end
		end

		local prevnode = nil

		-- Loop 2: Place dungeon pieces
		for nodeIdx = 0, numbernodes do
			local currentRowNode = nodesFolder:FindFirstChild("node" .. nodeIdx)
			if not currentRowNode then
				warn("Could not find currentRowNode node" .. nodeIdx)
				continue
			end

			local currentWidth = math.round(width)
			local num = math.random(-1 * currentWidth, currentWidth)

			local lastnode
			if prevnode then
				lastnode = prevnode
			else
				lastnode = currentRowNode:FindFirstChild("node0")
			end

			if not lastnode then
				warn("Could not determine lastnode for row " .. nodeIdx)
				continue
			end

			local currnode = currentRowNode:FindFirstChild("node" .. tostring(num))
			if not currnode then
				currnode = currentRowNode:FindFirstChild("node0")
				if not currnode then
					continue
				end
			end

			local continuationnode = currentRowNode:FindFirstChild(lastnode.Name) or lastnode
			if not continuationnode then
				continue
			end

			currnode.Orientation = Vector3.new(0, -90, 0)

			-- Place the 4-way at the continuation point
			local fourway = getPieceTemplate("4Way")
			if fourway then
				local fourwayClone = fourway:Clone()
				fourwayClone.Parent = continuationnode
				fourwayClone:PivotTo(continuationnode.CFrame)
			end

			-- Place the 3-way at the new random point (if it's different)
			if currnode ~= continuationnode then
				local threeway = getPieceTemplate("3Way")
				if threeway then
					local threewayClone = threeway:Clone()
					threewayClone.Parent = currnode
					threewayClone:PivotTo(currnode.CFrame)
				end
			end

			currnode.BrickColor = BrickColor.new("Sea green")
			continuationnode.BrickColor = BrickColor.new("Sea green")

			-- Fill in the gaps between continuation and current node
			local cindex = continuationnode:GetAttribute("index")
			local cuindex = currnode:GetAttribute("index")
			local mamount

			if cindex < cuindex then
				mamount = 1
			elseif cindex > cuindex then
				mamount = -1
			end

			if mamount then
				-- Gap fill placement
				repeat
					cuindex -= mamount

					if cuindex ~= cindex then
						local fillNode = currentRowNode:FindFirstChild("node" .. cuindex)
						if fillNode and fillNode ~= continuationnode and fillNode ~= currnode then
							-- Select template (1WayT or 1Way)
							local onewayName = (math.random(1, 2) == 1) and "1WayT" or "1Way"
							local oneway = getPieceTemplate(onewayName)
							if oneway then
								local onewayClone = oneway:Clone()
								onewayClone.Parent = fillNode
								onewayClone:PivotTo(fillNode.CFrame)
								fillNode.BrickColor = BrickColor.new("Sea green")
							end
						end
					end
				until cindex == cuindex
			end

			-- Fill in remaining empty nodes in the row
			local prevNodeWas1Way = false
			local w = math.round(width)

			for j = -w, w do
				local node = currentRowNode:FindFirstChild("node" .. j)

				if not node then
					continue
				end

				-- Check if node already has a piece
				local hasPiece = false
				for _, child in ipairs(node:GetChildren()) do
					if child.Name:find("Way") then
						hasPiece = true
						local name = "1Way"
						local randomnumber = math.random(1, 3)

						if randomnumber == 1 then
							name = "4Way"
						end
						if child.Name == name then
							prevNodeWas1Way = true
						else
							prevNodeWas1Way = false
						end
						break
					end
				end

				if not hasPiece then
					local peiceName = ""
					local chosen = 0

					if prevNodeWas1Way then
						chosen = math.random(1, 4)

						if math.random(1, 3) == 1 then
							peiceName = "" .. chosen .. "WayT"
						else
							peiceName = "" .. chosen .. "Way"
						end
					else
						if math.random(1, 3) == 1 then
							peiceName = "1Way"

							if math.random(1, 2) == 1 then
								peiceName = "1WayT"
							end
						else
							chosen = math.random(2, 4)
							if math.random(1, 3) == 1 then
								peiceName = "" .. chosen .. "WayT"
							else
								peiceName = "" .. chosen .. "Way"
							end
						end
					end

					-- Use cached template
					local peice = getPieceTemplate(peiceName)

					if peice then
						local peiceClone = peice:Clone()
						peiceClone.Parent = node
						peiceClone:PivotTo(node.CFrame)

						if peiceName == "1Way" then
							prevNodeWas1Way = true
						else
							prevNodeWas1Way = false
						end
					else
						warn("Could not find piece: " .. peiceName)
						prevNodeWas1Way = false
					end
				end
			end

			prevnode = currnode
		end

		task.wait(0.2)
		Exit.Position = Vector3.new(Exit.Position.X, Exit.Position.Y, Exit.Position.Z + 2)
		width -= 0.2
		halllenght -= 0.2
		prevfloor = floor
	end

	-- Generation wait per floor
	task.wait(0.1)
end

print("Dungeon generation script finished.")
