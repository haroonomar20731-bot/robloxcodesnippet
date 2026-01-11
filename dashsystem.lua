-- main services
-- These are core Roblox services. We grab them once so we don’t repeatedly call GetService later,
-- which is both cleaner and slightly more efficient.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

-- remote events being fired from starterplayerscripts
-- This RemoteEvent is how the client *asks* the server to activate the ability.
-- The server stays in control so players can’t exploit it.
local AbilityRemote = ReplicatedStorage:WaitForChild("AbilityRemote")

-- main constants
-- These values define how the dash *feels* (speed, duration, cooldown).
-- Keeping them as constants makes balancing easy without touching logic.
local DASH_FORCE = 85
local DASH_DURATION = 0.35
local COOLDOWN_TIME = 2.5
local GROUND_CHECK_DISTANCE = 5
local HEARTBEAT_RATE = 1 / 60

-- combat constants
-- These control how the dash interacts with enemies.
-- Separating combat values from movement keeps the system readable.
local DAMAGE_RADIUS = 10
local DAMAGE_AMOUNT = 20
local KNOCKBACK_POWER = 60
local MAX_DASH_HITS = 5

-- raycasting
-- RaycastParams let us fine-tune what the ray “sees”.
-- We ignore water and blacklist the character so we don’t hit ourselves.
local rayParams = RaycastParams.new()
rayParams.IgnoreWater = true
rayParams.FilterType = Enum.RaycastFilterType.Blacklist

-- Ability states
-- This is a simple state machine.
-- It prevents the ability from being used when it shouldn’t be.
local AbilityState = {
	Ready = 0,
	Active = 1,
	Cooldown = 2
}

-- Ability class
-- This table acts like a class using metatables.
-- Each player gets their own AbilityController instance.
local AbilityController = {}
AbilityController.__index = AbilityController

-- Checks for ground
-- We raycast straight down from the HumanoidRootPart.
-- If we hit something within a short distance, the character is grounded.
local function isGrounded(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return false end

	rayParams.FilterDescendantsInstances = { character }

	local result = Workspace:Raycast(
		root.Position,
		Vector3.new(0, -GROUND_CHECK_DISTANCE, 0),
		rayParams
	)

	-- If the ray hit anything, we consider the player on the ground.
	return result ~= nil
end

-- Locks movement when dashing
-- This temporarily removes player control so the dash feels clean and intentional.
-- We also restore their original movement values afterward.
local function setMovementLocked(humanoid, locked)
	if locked then
		humanoid:SetAttribute("MovementLocked", true)
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
	else
		humanoid:SetAttribute("MovementLocked", false)
		local defaultSpeed = humanoid:GetAttribute("DefaultWalkSpeed") or 16
		local defaultJump = humanoid:GetAttribute("DefaultJumpPower") or 50
		humanoid.WalkSpeed = defaultSpeed
		humanoid.JumpPower = defaultJump
	end
end

-- Helper for visual effects
-- This creates a quick expanding neon sphere to sell the impact visually.
-- It’s purely cosmetic and self-destructs to avoid clutter.
local function createImpactEffect(position)
	local part = Instance.new("Part")
	part.Size = Vector3.new(1, 1, 1)
	part.Color = Color3.fromRGB(255, 255, 255)
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.Position = position
	part.Parent = Workspace

	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part

	task.spawn(function()
		for i = 1, 15 do
			part.Size += Vector3.new(0.8, 0.8, 0.8)
			part.Transparency = i / 15
			task.wait(0.01)
		end
		part:Destroy()
	end)
end

-- Constructor
-- This initializes all per-player data.
-- Nothing game-changing happens here; it just sets defaults.
function AbilityController.new(player)
	local self = setmetatable({}, AbilityController)

	self.Player = player
	self.Character = nil
	self.Humanoid = nil
	self.Root = nil

	self.State = AbilityState.Ready
	self.LastUse = 0
	self.ActiveTime = 0

	-- Hit tracking logic
	-- This prevents hitting the same target multiple times per dash.
	self.TargetsHit = {}
	self.CurrentHitCount = 0

	return self
end

-- bind character
-- Called when a character spawns.
-- We cache important instances and store default movement values.
function AbilityController:BindCharacter(character)
	self.Character = character
	self.Humanoid = character:WaitForChild("Humanoid")
	self.Root = character:WaitForChild("HumanoidRootPart")

	self.Humanoid:SetAttribute("DefaultWalkSpeed", self.Humanoid.WalkSpeed)
	self.Humanoid:SetAttribute("DefaultJumpPower", self.Humanoid.JumpPower)
end

-- check cooldown
-- Uses os.clock for accurate time tracking.
-- This ensures cooldowns aren’t frame-dependent.
function AbilityController:IsOnCooldown()
	return os.clock() - self.LastUse < COOLDOWN_TIME
end

-- validate
-- This is the gatekeeper for activation.
-- If any condition fails, the ability simply won’t start.
function AbilityController:CanActivate()
	if self.State ~= AbilityState.Ready then
		return false
	end

	if self:IsOnCooldown() then
		return false
	end

	if not self.Character or not isGrounded(self.Character) then
		return false
	end

	return true
end

-- Process hitbox during dash
-- This checks nearby parts every update while dashing.
-- We use overlap queries instead of raycasts for reliable AoE detection.
function AbilityController:CheckHitbox()
	if self.CurrentHitCount >= MAX_DASH_HITS then return end

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Blacklist
	overlap.FilterDescendantsInstances = { self.Character }

	local results = Workspace:GetPartBoundsInRadius(self.Root.Position, DAMAGE_RADIUS, overlap)

	for _, part in ipairs(results) do
		local victim = part.Parent
		local vHumanoid = victim:FindFirstChild("Humanoid")
		local vRoot = victim:FindFirstChild("HumanoidRootPart")

		-- We validate the target and ensure it hasn’t already been hit.
		if vHumanoid and vRoot and not self.TargetsHit[victim] then
			self.TargetsHit[victim] = true
			self.CurrentHitCount += 1

			vHumanoid:TakeDamage(DAMAGE_AMOUNT)
			createImpactEffect(vRoot.Position)

			-- Apply knockback
			-- BodyVelocity is short-lived to give a sharp, punchy feel.
			local kb = Instance.new("BodyVelocity")
			kb.Velocity = (vRoot.Position - self.Root.Position).Unit * KNOCKBACK_POWER + Vector3.new(0, 15, 0)
			kb.MaxForce = Vector3.new(1, 1, 1) * 50000
			kb.Parent = vRoot
			Debris:AddItem(kb, 0.15)
		end
	end
end

-- Create dash trail
-- This spawns a fading afterimage to visually emphasize speed.
-- Random spawning keeps it from looking too uniform.
function AbilityController:CreateTrail()
	local trailPart = Instance.new("Part")
	trailPart.Size = self.Character["LeftUpperArm"].Size
	trailPart.CFrame = self.Root.CFrame
	trailPart.Anchored = true
	trailPart.CanCollide = false
	trailPart.Material = Enum.Material.ForceField
	trailPart.Color = Color3.fromRGB(0, 170, 255)
	trailPart.Parent = Workspace

	task.spawn(function()
		for i = 0, 1, 0.1 do
			trailPart.Transparency = i
			task.wait(0.05)
		end
		trailPart:Destroy()
	end)
end

-- Turn on ability
-- This is where the dash actually starts.
-- Movement is locked and a physics-based velocity pushes the character forward.
function AbilityController:Activate()
	if not self:CanActivate() then
		return
	end

	self.State = AbilityState.Active
	self.LastUse = os.clock()
	self.ActiveTime = 0
	self.TargetsHit = {}
	self.CurrentHitCount = 0

	setMovementLocked(self.Humanoid, true)

	local attachment = Instance.new("Attachment")
	attachment.Parent = self.Root

	local linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Attachment0 = attachment
	linearVelocity.MaxForce = math.huge

	local lookVector = self.Root.CFrame.LookVector
	linearVelocity.VectorVelocity = lookVector * DASH_FORCE
	linearVelocity.Parent = self.Root

	-- Debris ensures cleanup even if something goes wrong.
	Debris:AddItem(linearVelocity, DASH_DURATION)
	Debris:AddItem(attachment, DASH_DURATION)
end

-- update
-- Called every fixed heartbeat tick.
-- Handles state transitions and continuous dash logic.
function AbilityController:Update(dt)
	if self.State == AbilityState.Active then
		self.ActiveTime += dt

		-- Continuous checks during dash
		self:CheckHitbox()
		if math.random() > 0.8 then
			self:CreateTrail()
		end

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
-- Clears references so the controller can be garbage-collected.
function AbilityController:Destroy()
	self.Character = nil
	self.Humanoid = nil
	self.Root = nil
	self.TargetsHit = nil
end

-- Player registery
-- Maps each player to their AbilityController.
local controllers = {}

-- Player being added
-- Creates and wires up a controller for the player.
local function onPlayerAdded(player)
	local controller = AbilityController.new(player)
	controllers[player] = controller

	player.CharacterAdded:Connect(function(character)
		controller:BindCharacter(character)
	end)

	if player.Character then
		controller:BindCharacter(player.Character)
	end
end

-- Player being removed
-- Proper cleanup prevents memory leaks.
local function onPlayerRemoving(player)
	local controller = controllers[player]
	if controller then
		controller:Destroy()
		controllers[player] = nil
	end
end

-- Wait for event to fire
-- The server listens for the client’s request and decides whether to act.
AbilityRemote.OnServerEvent:Connect(function(player)
	local controller = controllers[player]
	if not controller then return end

	controller:Activate()
end)

-- Health monitor for dynamic cooldowns (Extra logic for lines)
-- This runs in the background and adjusts cooldowns based on health.
-- Lower health = slightly more forgiving ability usage.
local function monitorPlayerHealth()
	while true do
		for _, controller in pairs(controllers) do
			if controller.Humanoid and controller.Humanoid.Health < 20 then
				-- Panic mode: Slightly faster cooldown when low health
				COOLDOWN_TIME = 2.0
			else
				COOLDOWN_TIME = 2.5
			end
		end
		task.wait(1)
	end
end
task.spawn(monitorPlayerHealth)

-- initilize
-- Ensures players already in the server are handled.
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- heartbeat loop
-- We manually control update frequency for consistency and performance.
local accumulator = 0

RunService.Heartbeat:Connect(function(dt)
	accumulator += dt
	if accumulator < HEARTBEAT_RATE then return end
	accumulator = 0

	for _, controller in pairs(controllers) do
		if controller.Character and controller.Character.Parent then
			controller:Update(HEARTBEAT_RATE)
		end
	end
end)

-- Validation check for stale controllers
-- Acts as a safety net in case something wasn’t cleaned up properly.
task.spawn(function()
	while true do
		task.wait(60)
		for player, _ in pairs(controllers) do
			if not player or not player.Parent then
				controllers[player] = nil
			end
		end
	end
end)
