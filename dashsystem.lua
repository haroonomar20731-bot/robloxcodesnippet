-- main services
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

-- remote events being fired from starterplayerscripts
local AbilityRemote = ReplicatedStorage:WaitForChild("AbilityRemote")

-- main constants
local DASH_FORCE = 85
local DASH_DURATION = 0.35
local COOLDOWN_TIME = 2.5
local GROUND_CHECK_DISTANCE = 5
local HEARTBEAT_RATE = 1 / 60

-- raycasting
local rayParams = RaycastParams.new()
rayParams.IgnoreWater = true
rayParams.FilterType = Enum.RaycastFilterType.Blacklist

-- Ability states
local AbilityState = {
	Ready = 0,
	Active = 1,
	Cooldown = 2
}

-- Ability class
local AbilityController = {}
AbilityController.__index = AbilityController

-- Checks for ground
local function isGrounded(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	rayParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(
		root.Position,
		Vector3.new(0, -GROUND_CHECK_DISTANCE, 0),
		rayParams
	)

	return result ~= nil
end

-- Locks movement when dashing
local function setMovementLocked(humanoid, locked)
	if locked then
		humanoid:SetAttribute("MovementLocked", true)
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	else
		humanoid:SetAttribute("MovementLocked", false)
		humanoid.WalkSpeed = humanoid:GetAttribute("DefaultWalkSpeed")
		humanoid.JumpPower = humanoid:GetAttribute("DefaultJumpPower")
	end
end

-- Constructor
function AbilityController.new(player)
	local self = setmetatable({}, AbilityController)

	self.Player = player
	self.Character = nil
	self.Humanoid = nil
	self.Root = nil

	self.State = AbilityState.Ready
	self.LastUse = 0
	self.ActiveTime = 0

	return self
end

-- bind character
function AbilityController:BindCharacter(character)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid")
	self.Root = character:WaitForChild("HumanoidRootPart")

	self.Humanoid:SetAttribute("DefaultWalkSpeed", self.Humanoid.WalkSpeed)
	self.Humanoid:SetAttribute("DefaultJumpPower", self.Humanoid.JumpPower)
end

-- check cooldown
function AbilityController:IsOnCooldown()
	return os.clock() - self.LastUse < COOLDOWN_TIME
end

-- validate
function AbilityController:CanActivate()
	if self.State ~= AbilityState.Ready then
		return false
	end

	if self:IsOnCooldown() then
		return false
	end

	if not isGrounded(self.Character) then
		return false
	end

	return true
end

-- Turn on ability
function AbilityController:Activate()
	if not self:CanActivate() then
		return
	end

	self.State = AbilityState.Active
	self.LastUse = os.clock()
	self.ActiveTime = 0

	setMovementLocked(self.Humanoid, true)

	local attachment = Instance.new("Attachment")
	attachment.Parent = self.Root

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = math.huge

	local lookVector = self.Root.CFrame.LookVector
	linearVelocity.VectorVelocity = lookVector * DASH_FORCE
	linearVelocity.Parent = self.Root

	Debris:AddItem(linearVelocity, DASH_DURATION)
	Debris:AddItem(attachment, DASH_DURATION)
end

-- update
function AbilityController:Update(dt)
	if self.State == AbilityState.Active then
		self.ActiveTime += dt

		if self.ActiveTime >= DASH_DURATION then
			self.State = AbilityState.Cooldown
			setMovementLocked(self.Humanoid, false)
		end
	elseif self.State == AbilityState.Cooldown then
		if not self:IsOnCooldown() then
			self.State = AbilityState.Ready
		end
	end
end

-- End
function AbilityController:Destroy()
	self.Character = nil
	self.Humanoid = nil
	self.Root = nil
end

-- Player registery
local controllers = {}

-- Player being added
local function onPlayerAdded(player)
	local controller = AbilityController.new(player)
	controllers[player] = controller

	player.CharacterAdded:Connect(function(character)
		controller:BindCharacter(character)
	end)
end

-- Player being removed
local function onPlayerRemoving(player)
	local controller = controllers[player]
	if controller then
		controller:Destroy()
		controllers[player] = nil
	end
end

-- Wait for event to fire
AbilityRemote.OnServerEvent:Connect(function(player)
	local controller = controllers[player]
	if not controller then return end

	controller:Activate()
end)

-- initilize
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- heartbeat loop
local accumulator = 0

RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < HEARTBEAT_RATE then return end
	accumulator = 0

	for _, controller in pairs(controllers) do
		if controller.Character then
			controller:Update(HEARTBEAT_RATE)
		end
	end
end)
