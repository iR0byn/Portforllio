local module = {}

function module.AddItem(thing, player)
	local pdata = player:WaitForChild("pdata")
	local inventory = player:WaitForChild("pdata"):WaitForChild("Inventory")
	local items = inventory.Items

	local slots = pdata.keys
	local skills = inventory.skills

	if thing and thing:HasTag("Item") then
		local foundexisting = false
		local existing = nil

		for _, item in ipairs(items:GetChildren()) do
			if item:FindFirstChild("Itemname") then
				if item.Itemname.Value == thing.Name then
					foundexisting = true
					existing = item
				end
			end

			if item:FindFirstChild("ItemType") then
				if item:HasTag("Weapon") then
					if item.ItemType.Value == "Weapon" then
					end
				end
			end
		end

		local notif = script.PickupManager:Clone()
		notif.Parent = player.PlayerGui.Hotbar.Pickup
		notif.TextLabel.Text = thing.Name
		notif.Name = thing.Name

		task.spawn(function()
			task.wait(2)
			notif:Destroy()
		end)

		if foundexisting and existing then
			existing.Value += 1

			thing:Destroy()
			return true
		else
			for _, item in ipairs(items:GetChildren()) do
				if item:FindFirstChild("Itemname") and thing then
					if item.Itemname.Value == "" then
						item.Itemname.Value = thing.Name
						item.Value = 1

						thing:Destroy()
						return true
					end
				end
			end
		end
	elseif thing:HasTag("Skill") and thing then
		local existing = nil

		for _, keyslot in ipairs(slots:GetChildren()) do
			if keyslot:FindFirstChild("Name") then
				if keyslot:FindFirstChild("Name").Value == "" and not existing then
					existing = keyslot
				end
			end
		end

		if existing == nil then
			for _, item in ipairs(slots:GetChildren()) do
				if item:FindFirstChild("SkillName") then
					if item.SkillName.Value == "" and not existing then
						existing = item
					end
				end
			end
		end

		if existing and thing then
			existing:FindFirstChild("Name").Value = thing.Name

			local number = game.ReplicatedStorage.Items.Skills:FindFirstChild(thing.Name):Clone()
			number.Parent = existing
			number.Name = thing.Name
			number.Value = 1

			thing:Destroy()
		end
	end
end
function module.DropItem(thing, player)
	local pdata = player:WaitForChild("pdata")
	local inventory = player:WaitForChild("pdata"):WaitForChild("Inventory")
	local items = inventory.Items

	local slots = pdata.keys
	local skills = inventory.skills

	if thing and thing:HasTag("Item") then
		local foundexisting = false
		local existing = nil

		for _, item in ipairs(items:GetChildren()) do
			if item:FindFirstChild("Itemname") then
				if item.Itemname.Value == thing.Name or item.Itemname.Value .. "D" == thing.Name then
					foundexisting = true
					existing = item
				end
			end
		end
		if foundexisting and thing then
			--("droping item ")
			existing.Value -= 1
			if existing.Value <= 0 then
				existing.Value = 0
				existing.Itemname.Value = ""
				existing.ItemType.Value = ""
				existing.Rarity1.Value = ""
			end

			local item = thing:Clone()
			item.Parent = game.Workspace

			item:PivotTo(player.Character.PrimaryPart.CFrame * CFrame.new(0, 0, -5))
		end
	end
end

return module
