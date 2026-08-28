-- Connected Discord-GitHub
--!strict

--[[
	ARCLINE COMBAT
	Server-authoritative combat / ability demonstration for HiddenDevs.

	The central security model is intentionally simple:
	the client may request an ability and provide an aim direction,
	but the server owns the ability definition, origin, target query,
	damage, cooldown, movement restrictions and resulting state.

	This file is intentionally self-contained so it can be placed into an
	empty Roblox baseplate without companion scripts. It provisions its own
	network objects, creates a small demonstration arena, and exposes the
	same validated execution path to both RemoteEvent requests and demo Tools.

	The implementation uses a small internal service lifecycle inspired by
	the author's private framework design, but contains no private framework
	source. The goal is to demonstrate engineering decisions rather than
	simply accumulate lines of code.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

--== CONFIGURATION ====================================================

local CONFIG = {
	-- The token bucket limits request pressure independently from per-ability
	-- cooldowns. Cooldown answers "may this ability happen yet?" while the
	-- bucket answers "is this caller allowed to make another request at all?"
	BucketSize = 8,
	BucketRefillPerSecond = 5,

	-- Aim is intentionally constrained to a useful combat cone. A client can
	-- therefore not submit an arbitrary vertical direction to bypass the
	-- expected shape of the abilities.
	MaxAimPitch = 0.72,

	-- Every externally visible impulse is clamped. This makes the maximum
	-- movement result deterministic even if several effects are introduced
	-- later and happen to stack during the same frame.
	MaxImpulse = 110,
	KnockbackLift = 0.35,

	-- Overlap queries return parts, not characters. Limiting their result size
	-- bounds worst-case work before the resolver starts processing candidates.
	MaxQueryParts = 64,
	ArcVerticalTolerance = 7,

	-- Movement speed is owned by the server. Committed states cannot be
	-- extended by the client because the duration is calculated from ability
	-- configuration on the server.
	BaseWalkSpeed = 16,
	CommittedWalkSpeed = 7,

	-- Training arena settings used by the demonstration bootstrap.
	ArenaSize = 180,
	ArenaWallHeight = 16,
	TrainingTargetCount = 6,
	TrainingTargetSpacing = 18,

	-- Visual feedback is intentionally lightweight. The effects are created
	-- by the server and removed automatically so the demo does not accumulate
	-- permanent Instances while the reviewer tests repeated attacks.
	DebugVisualLifetime = 0.18,
}

table.freeze(CONFIG)

--== ABILITY DATA =====================================================

type Ability = {
	Kind: string,
	Cooldown: number,
	Commit: number,

	Damage: number?,
	Range: number?,
	ArcCosine: number?,
	Falloff: number?,

	Knockback: number?,
	Impulse: number?,
	Lift: number?,
}

-- The combat resolver is selected by data instead of a large if/elseif chain.
-- This keeps ability definitions declarative: designers can change values
-- without modifying the execution pipeline itself.
local ABILITIES: { [string]: Ability } = {
	-- cos(65 degrees), precomputed so the hot path performs a comparison
	-- instead of calling inverse trigonometry for every potential target.
	Cleave = {
		Kind = "Arc",
		Cooldown = 0.75,
		Commit = 0.30,
		Damage = 16,
		Range = 12,
		ArcCosine = 0.4226,
		Knockback = 38,
	},

	Bolt = {
		Kind = "Ray",
		Cooldown = 1.50,
		Commit = 0.22,
		Damage = 27,
		Range = 95,
		Falloff = 0.45,
		Knockback = 26,
	},

	Lunge = {
		Kind = "Mobility",
		Cooldown = 3.50,
		Commit = 0.40,
		Impulse = 82,
		Lift = 22,
	},
}

local ABILITY_ORDER = {
	"Cleave",
	"Bolt",
	"Lunge",
}

for _, ability in ABILITIES do
	table.freeze(ability)
end

table.freeze(ABILITIES)
table.freeze(ABILITY_ORDER)

--== SIGNAL ===========================================================

type SignalSlot = {
	fn: (...any) -> (),
	alive: boolean,
}

local Signal = {}
Signal.__index = Signal

type Signal = typeof(setmetatable({} :: {
	_slots: { SignalSlot },
	_depth: number,
	_dirty: boolean,
}, Signal))

function Signal.new(): Signal
	return setmetatable({
		_slots = {},
		_depth = 0,
		_dirty = false,
	}, Signal)
end

function Signal:Connect(handler: (...any) -> ()): { Disconnect: () -> () }
	assert(type(handler) == "function", "Signal handler must be a function")

	local slot: SignalSlot = {
		fn = handler,
		alive = true,
	}

	table.insert(self._slots, slot)

	-- Disconnect is a logical operation during dispatch. Physically removing a
	-- listener while the array is being iterated can shift later entries and
	-- skip them. Deferred compaction keeps dispatch stable even when listeners
	-- remove themselves or other listeners.
	return {
		Disconnect = function()
			if not slot.alive then
				return
			end

			slot.alive = false
			self._dirty = true

			if self._depth == 0 then
				self:_compact()
			end
		end,
	}
end

function Signal:Fire(...: any)
	self._depth += 1

	local slots = self._slots

	-- Dispatch is intentionally asynchronous. A signal represents an observer
	-- boundary rather than a transaction: one listener may yield or throw
	-- without holding the system that emitted the signal hostage. Code that
	-- requires an immediate return value or strict transactional ordering uses
	-- a direct function call instead of this signal primitive.
	for index = 1, #slots do
		local slot = slots[index]

		if slot.alive then
			task.spawn(slot.fn, ...)
		end
	end

	self._depth -= 1

	if self._depth == 0 and self._dirty then
		self:_compact()
	end
end

function Signal:_compact()
	local slots = self._slots

	for index = #slots, 1, -1 do
		if not slots[index].alive then
			table.remove(slots, index)
		end
	end

	self._dirty = false
end

function Signal:Destroy()
	table.clear(self._slots)
	self._dirty = false
	self._depth = 0
end

--== BIN ===============================================================

local Bin = {}
Bin.__index = Bin

type Bin = typeof(setmetatable({} :: {
	_items: { any },
}, Bin))

function Bin.new(): Bin
	return setmetatable({
		_items = {},
	}, Bin)
end

-- Ownership is registered when the resource is created. Cleanup is therefore
-- centralized instead of relying on every constructor having a matching list
-- of teardown calls somewhere else in the codebase.
function Bin:Add<T>(item: T): T
	table.insert(self._items, item)
	return item
end

local function disposeItem(item: any)
	local kind = typeof(item)

	if kind == "RBXScriptConnection" then
		item:Disconnect()

	elseif kind == "Instance" then
		item:Destroy()

	elseif kind == "function" then
		item()

	elseif kind == "table" and type(item.Disconnect) == "function" then
		item:Disconnect()

	elseif kind == "table" and type(item.Destroy) == "function" then
		item:Destroy()

	else
		-- A cleanup primitive that silently ignores unsupported resources can
		-- hide real leaks. Warning makes an incorrect ownership registration
		-- observable during development instead of silently accepting it.
		warn(`[Arcline/Bin] no disposer for {kind}`)
	end
end

function Bin:Destroy()
	local items = self._items

	-- Resources are released in reverse creation order. Later resources often
	-- depend on earlier ones, so reversing the construction graph is the safer
	-- default for nested connections, Instances and subscriptions.
	for index = #items, 1, -1 do
		local item = items[index]
		items[index] = nil

		local ok, err = pcall(disposeItem, item)

		if not ok then
			warn(`[Arcline/Bin] disposal failed: {err}`)
		end
	end
end

--== PLAYER STATE =====================================================

type PlayerState = {
	player: Player,

	bin: Bin,
	characterBin: Bin?,

	name: string,
	expiresAt: number,

	tokens: number,
	lastRefill: number,

	cooldowns: { [string]: number },
	loadout: { [string]: boolean },

	character: Model?,
	humanoid: Humanoid?,
	root: BasePart?,

	damageDealt: number,
	rejected: number,

	damageValue: IntValue?,
	rejectionValue: IntValue?,
}

--== FRAMEWORK ========================================================

local Framework = {
	_services = {} :: { [string]: any },
	_order = {} :: { any },
}

function Framework.Register(service: any)
	local name = assert(service.Name, "service is missing Name")

	assert(
		Framework._services[name] == nil,
		`duplicate service registration: {name}`
	)

	Framework._services[name] = service
	table.insert(Framework._order, service)
end

function Framework.Get(name: string): any
	return assert(
		Framework._services[name],
		`unknown service: {name}`
	)
end

function Framework.Ignite()
	-- Init is separated from Start so every service exists before any service
	-- tries to resolve a sibling. Declaration order therefore does not become
	-- an accidental dependency.
	for _, service in Framework._order do
		if service.Init then
			service:Init()
		end
	end

	-- Start runs only after the entire service registry has been constructed.
	for _, service in Framework._order do
		if service.Start then
			service:Start()
		end
	end
end

function Framework.Shutdown()
	-- Shutdown is the reverse of construction order. A service that depends on
	-- another service should normally release itself before that dependency.
	for index = #Framework._order, 1, -1 do
		local service = Framework._order[index]

		if service.Shutdown then
			local ok, err = pcall(service.Shutdown, service)

			if not ok then
				warn(
					`[Arcline/Framework] shutdown failed for {service.Name}: {err}`
				)
			end
		end
	end
end

--== SHARED HELPERS ===================================================

local function isFiniteNumber(value: any): boolean
	if type(value) ~= "number" then
		return false
	end

	return value == value
		and value ~= math.huge
		and value ~= -math.huge
end

local function sanitizeDirection(value: any): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end

	-- NaN compares unequal to itself. Catching it here prevents the invalid value
	-- from propagating into Unit/CFrame math and causing a failure much deeper
	-- inside the hit detection path.
	if value.X ~= value.X
		or value.Y ~= value.Y
		or value.Z ~= value.Z
	then
		return nil
	end

	if not isFiniteNumber(value.X)
		or not isFiniteNumber(value.Y)
		or not isFiniteNumber(value.Z)
	then
		return nil
	end

	local magnitude = value.Magnitude

	if magnitude < 1e-3 or magnitude > 1e6 then
		return nil
	end

	local unit = value.Unit

	-- A purely vertical input has no meaningful horizontal facing for this
	-- ability set. Rejecting it is safer than silently inventing a direction.
	if math.abs(unit.X) < 1e-4 and math.abs(unit.Z) < 1e-4 then
		return nil
	end

	local pitch = math.clamp(
		unit.Y,
		-CONFIG.MaxAimPitch,
		CONFIG.MaxAimPitch
	)

	return Vector3.new(
		unit.X,
		pitch,
		unit.Z
	).Unit
end

local function clampImpulse(impulse: Vector3): Vector3
	local magnitude = impulse.Magnitude

	if magnitude <= CONFIG.MaxImpulse then
		return impulse
	end

	if magnitude <= 1e-3 then
		return Vector3.zero
	end

	return impulse * (CONFIG.MaxImpulse / magnitude)
end

local function resolveTarget(part: BasePart): (Model?, Humanoid?, BasePart?)
	local model = part:FindFirstAncestorOfClass("Model") :: Model?

	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid?

		if humanoid then
			if humanoid.Health <= 0 then
				return nil, nil, nil
			end

			local root = (
				model:FindFirstChild("HumanoidRootPart")
				or model.PrimaryPart
			) :: BasePart?

			return model, humanoid, root
		end

		-- Nested models can exist inside real character hierarchies. Continue
		-- upward until a model containing a Humanoid is found.
		model = model:FindFirstAncestorOfClass("Model") :: Model?
	end

	return nil, nil, nil
end

local function ensureChild(
	parent: Instance,
	className: string,
	name: string
): Instance
	local existing = parent:FindFirstChild(name)

	if existing then
		return existing
	end

	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent

	return instance
end

local function createDebugPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	transparency: number
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = transparency
	part.Parent = parent

	return part
end

local function flashPart(
	cframe: CFrame,
	size: Vector3,
	duration: number
)
	local visualFolder = Workspace:FindFirstChild("ArclineDebug")

	if not visualFolder then
		visualFolder = Instance.new("Folder")
		visualFolder.Name = "ArclineDebug"
		visualFolder.Parent = Workspace
	end

	local part = createDebugPart(
		visualFolder,
		"CombatDebug",
		size,
		cframe,
		0.45
	)

	part.Material = Enum.Material.Neon

	Debris:AddItem(part, duration)
end

--== PLAYER STATE SERVICE =============================================

local PlayerStateService = {
	Name = "PlayerState",

	StateChanged = Signal.new(),
	CharacterReady = Signal.new(),

	_states = {} :: { [Player]: PlayerState },
	_bin = Bin.new(),
}

local STATE_RULES: {
	[string]: {
		[string]: boolean,
	},
} = {
	Ready = {
		Committed = true,
		Dashing = true,
		Downed = true,
	},

	Committed = {
		Ready = true,
		Downed = true,
	},

	Dashing = {
		Ready = true,
		Downed = true,
	},

	Downed = {
		Ready = true,
	},
}

function PlayerStateService:Get(player: Player): PlayerState?
	return self._states[player]
end

function PlayerStateService:SetState(
	state: PlayerState,
	name: string,
	duration: number?
): boolean
	if state.name == name then
		return true
	end

	local allowed = STATE_RULES[state.name]

	if not (allowed and allowed[name]) then
		return false
	end

	state.name = name

	-- os.clock() is monotonic process time. It is preferable here to wall-clock
	-- APIs because system clock corrections must not alter combat state expiry.
	state.expiresAt = if duration
		then os.clock() + duration
		else 0

	self.StateChanged:Fire(state.player, name)

	return true
end

function PlayerStateService:ConsumeToken(state: PlayerState): boolean
	local now = os.clock()
	local elapsed = now - state.lastRefill

	if elapsed > 0 then
		state.lastRefill = now

		state.tokens = math.min(
			CONFIG.BucketSize,
			state.tokens + elapsed * CONFIG.BucketRefillPerSecond
		)
	end

	if state.tokens < 1 then
		return false
	end

	state.tokens -= 1

	return true
end

function PlayerStateService:_bindCharacter(
	state: PlayerState,
	character: Model
)
	if state.characterBin then
		state.characterBin:Destroy()
	end

	local bin = Bin.new()
	state.characterBin = bin

	-- Bounded waits prevent a malformed/incomplete character from pinning the
	-- initialization thread forever.
	local humanoid = character:WaitForChild(
		"Humanoid",
		5
	) :: Humanoid?

	local root = character:WaitForChild(
		"HumanoidRootPart",
		5
	) :: BasePart?

	if not (humanoid and root) then
		return
	end

	-- Both WaitForChild calls yielded. Re-checking identity is therefore
	-- important: a fast respawn could have replaced the character while the
	-- function was waiting for its parts.
	if state.player.Character ~= character then
		return
	end

	state.character = character
	state.humanoid = humanoid
	state.root = root

	state.name = "Ready"
	state.expiresAt = 0

	-- Cooldowns describe the current life. Progression/loadout does not, so only
	-- temporary combat state is cleared on respawn.
	table.clear(state.cooldowns)

	humanoid.WalkSpeed = CONFIG.BaseWalkSpeed

	bin:Add(
		humanoid.Died:Connect(function()
			-- Death invalidates cached character references immediately. Any
			-- request that arrives during the transition therefore fails its
			-- liveness checks rather than operating on a dead rig.
			state.name = "Downed"
			state.expiresAt = 0

			state.character = nil
			state.humanoid = nil
			state.root = nil
		end)
	)

	self.CharacterReady:Fire(
		state.player,
		character
	)
end

function PlayerStateService:_onPlayerAdded(player: Player)
	local state: PlayerState = {
		player = player,

		bin = Bin.new(),
		characterBin = nil,

		name = "Ready",
		expiresAt = 0,

		tokens = CONFIG.BucketSize,
		lastRefill = os.clock(),

		cooldowns = {},
		loadout = {
			Cleave = true,
			Bolt = true,
			Lunge = true,
		},

		character = nil,
		humanoid = nil,
		root = nil,

		damageDealt = 0,
		rejected = 0,

		damageValue = nil,
		rejectionValue = nil,
	}

	self._states[player] = state

	-- leaderstats provide observable server-owned telemetry without requiring
	-- another UI script. The reviewer can see damage change while testing the
	-- actual server-side combat path.
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"

	local damage = Instance.new("IntValue")
	damage.Name = "Damage"
	damage.Parent = stats

	local rejected = Instance.new("IntValue")
	rejected.Name = "Rejected"
	rejected.Parent = stats

	stats.Parent = player

	state.damageValue = damage
	state.rejectionValue = rejected

	state.bin:Add(stats)

	state.bin:Add(
		player.CharacterAdded:Connect(function(character)
			self:_bindCharacter(
				state,
				character
			)
		end)
	)

	if player.Character then
		task.spawn(function()
			self:_bindCharacter(
				state,
				player.Character :: Model
			)
		end)
	end
end

function PlayerStateService:_onPlayerRemoving(player: Player)
	local state = self._states[player]

	if not state then
		return
	end

	if state.characterBin then
		state.characterBin:Destroy()
		state.characterBin = nil
	end

	state.bin:Destroy()

	-- Player-keyed state retains the Player object itself. Clearing the entry is
	-- therefore required for garbage collection after the player leaves.
	self._states[player] = nil
end

function PlayerStateService:Start()
	self._bin:Add(
		Players.PlayerAdded:Connect(function(player)
			self:_onPlayerAdded(player)
		end)
	)

	self._bin:Add(
		Players.PlayerRemoving:Connect(function(player)
			self:_onPlayerRemoving(player)
		end)
	)

	-- Existing players matter in Studio Play Solo and in servers where this
	-- service starts after Players has already populated.
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_onPlayerAdded(player)
		end)
	end

	self._bin:Add(
		RunService.Heartbeat:Connect(function()
			local now = os.clock()

			for _, state in self._states do
				if state.expiresAt > 0 and now >= state.expiresAt then
					state.expiresAt = 0

					if state.name ~= "Downed" then
						self:SetState(
							state,
							"Ready"
						)
					end
				end
			end
		end)
	)
end

function PlayerStateService:Shutdown()
	self._bin:Destroy()

	for player, state in self._states do
		if state.characterBin then
			state.characterBin:Destroy()
		end

		state.bin:Destroy()

		self._states[player] = nil
	end

	self.StateChanged:Destroy()
	self.CharacterReady:Destroy()
end

Framework.Register(PlayerStateService)

--== COMBAT SERVICE ===================================================

local CombatService = {
	Name = "Combat",

	DamageDealt = Signal.new(),
	RequestRejected = Signal.new(),
	AbilityExecuted = Signal.new(),

	_players = nil :: any,
	_net = nil :: Folder?,
	_feedback = nil :: RemoteEvent?,

	_bin = Bin.new(),
}

type Resolver = (
	self: any,
	state: PlayerState,
	ability: Ability,
	direction: Vector3
) -> number

local RESOLVERS: {
	[string]: Resolver,
} = {}

function CombatService:Init()
	self._players = Framework.Get("PlayerState")
end

function CombatService:_notify(
	player: Player,
	abilityId: string,
	accepted: boolean,
	hits: number,
	reason: string
)
	local feedback = self._feedback

	if not feedback then
		return
	end

	if not player.Parent then
		return
	end

	-- Feedback only goes to the requesting player. Broadcasting another player's
	-- rejection reasons would add bandwidth cost without providing gameplay value.
	feedback:FireClient(
		player,
		abilityId,
		accepted,
		hits,
		reason
	)
end

function CombatService:_reject(
	state: PlayerState,
	abilityId: string,
	reason: string
): (boolean, string)
	state.rejected += 1

	if state.rejectionValue then
		state.rejectionValue.Value = state.rejected
	end

	self.RequestRejected:Fire(
		state.player,
		abilityId,
		reason
	)

	self:_notify(
		state.player,
		abilityId,
		false,
		0,
		reason
	)

	return false, reason
end

function CombatService:_applyHit(
	state: PlayerState,
	ability: Ability,
	humanoid: Humanoid,
	targetRoot: BasePart?,
	pushDirection: Vector3,
	damage: number
)
	if humanoid.Health <= 0 then
		return
	end

	-- All damage originates from server-side configuration. The client cannot
	-- submit the amount, so changing the requested direction cannot become a
	-- direct damage injection.
	humanoid:TakeDamage(damage)

	local knockback = ability.Knockback

	if targetRoot and knockback and targetRoot.Parent then
		local flat = Vector3.new(
			pushDirection.X,
			0,
			pushDirection.Z
		)

		if flat.Magnitude > 1e-3 then
			-- A direct velocity result is intentional. Knockback is an
			-- instantaneous combat consequence, so creating a temporary
			-- constraint would introduce another object lifetime and cleanup
			-- path without adding meaningful control for this demonstration.
			local impulse =
				flat.Unit * knockback
				+ Vector3.yAxis * (knockback * CONFIG.KnockbackLift)

			targetRoot.AssemblyLinearVelocity =
				clampImpulse(impulse)
		end
	end

	self.DamageDealt:Fire(
		state.player,
		humanoid,
		damage
	)
end

function CombatService:_resolveArc(
	state: PlayerState,
	ability: Ability,
	direction: Vector3
): number
	local root = state.root :: BasePart
	local character = state.character :: Model

	local origin = root.Position
	local facing = CFrame.lookAt(
		origin,
		origin + direction
	)

	local range = ability.Range :: number

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		character,
	}

	params.MaxParts = CONFIG.MaxQueryParts

	local struck: {
		[Model]: boolean,
	} = {}

	local hits = 0

	local parts = Workspace:GetPartBoundsInRadius(
		origin,
		range,
		params
	)

	-- The broadphase is bounded before per-target processing. This keeps a
	-- single ability from becoming arbitrarily expensive in a crowded arena.
	for _, part in parts do
		local model, humanoid, targetRoot =
			resolveTarget(part)

		if model
			and humanoid
			and targetRoot
			and not struck[model]
		then
			local targetOffset =
				targetRoot.Position - origin

			-- Bounding-box overlap is a broadphase. This explicit distance test
			-- makes the final hit decision depend on the target root's position,
			-- not on a limb or accessory that happened to enter the query sphere.
			if targetOffset.Magnitude > range then
				continue
			end

			local offset =
				facing:PointToObjectSpace(
					targetRoot.Position
				)

			local forward = -offset.Z

			if forward > 0
				and math.abs(offset.Y)
					<= CONFIG.ArcVerticalTolerance
			then
				local flat = math.sqrt(
					offset.X * offset.X
					+ offset.Z * offset.Z
				)

				if flat > 1e-4
					and (forward / flat)
						>= (ability.ArcCosine :: number)
				then
					struck[model] = true
					hits += 1

					self:_applyHit(
						state,
						ability,
						humanoid,
						targetRoot,
						targetRoot.Position - origin,
						ability.Damage :: number
					)

					flashPart(
						CFrame.lookAt(
							origin + direction * 4,
							origin + direction * 4 + direction
						),
						Vector3.new(0.25, 0.25, math.max(1, range * 0.4)),
						CONFIG.DebugVisualLifetime
					)
				end
			end
		end
	end

	return hits
end

function CombatService:_resolveRay(
	state: PlayerState,
	ability: Ability,
	direction: Vector3
): number
	local root = state.root :: BasePart
	local character = state.character :: Model

	-- Chest height avoids beginning the ray inside the floor or near the feet.
	local origin =
		root.Position + Vector3.yAxis * 1.5

	local range = ability.Range :: number

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {
		character,
	}
	params.IgnoreWater = true

	local result = Workspace:Raycast(
		origin,
		direction * range,
		params
	)

	-- The path itself is visualized after the actual query. The visual therefore
	-- reflects the server-calculated origin and requested direction rather than
	-- a client-created fake trajectory.
	local endPoint =
		if result
		then result.Position
		else origin + direction * range

	local length =
		(endPoint - origin).Magnitude

	local midpoint =
		origin + direction * (length * 0.5)

	flashPart(
		CFrame.lookAt(
			midpoint,
			midpoint + direction
		),
		Vector3.new(0.12, 0.12, math.max(length, 0.2)),
		CONFIG.DebugVisualLifetime
	)

	if not result then
		return 0
	end

	local _, humanoid, targetRoot =
		resolveTarget(result.Instance)

	if not humanoid then
		return 0
	end

	-- Falloff uses the actual impact point. The client is never trusted to
	-- choose a travelled distance separately from the direction of the shot.
	local travelled =
		(result.Position - origin).Magnitude

	local ratio =
		math.clamp(
			travelled / range,
			0,
			1
		)

	local falloff =
		ability.Falloff :: number

	local damage =
		(ability.Damage :: number)
		* (1 - ratio * (1 - falloff))

	self:_applyHit(
		state,
		ability,
		humanoid,
		targetRoot,
		direction,
		damage
	)

	return 1
end

function CombatService:_resolveMobility(
	state: PlayerState,
	ability: Ability,
	direction: Vector3
): number
	local root = state.root :: BasePart

	local result =
		direction * (ability.Impulse :: number)
		+ Vector3.yAxis * (ability.Lift :: number)

	root.AssemblyLinearVelocity =
		clampImpulse(result)

	flashPart(
		CFrame.lookAt(
			root.Position,
			root.Position + direction
		),
		Vector3.new(1.2, 1.2, 1.2),
		CONFIG.DebugVisualLifetime
	)

	return 0
end

RESOLVERS = {
	Arc = CombatService._resolveArc,
	Ray = CombatService._resolveRay,
	Mobility = CombatService._resolveMobility,
}

--== STATIC CONFIGURATION VALIDATION ================================

local REQUIRED_FIELDS: {
	[string]: { string },
} = {
	Arc = {
		"Damage",
		"Range",
		"ArcCosine",
		"Knockback",
	},

	Ray = {
		"Damage",
		"Range",
		"Falloff",
		"Knockback",
	},

	Mobility = {
		"Impulse",
		"Lift",
	},
}

for abilityId, ability in ABILITIES do
	local required =
		assert(
			REQUIRED_FIELDS[ability.Kind],
			`ability "{abilityId}" has unknown kind "{ability.Kind}"`
		)

	assert(
		RESOLVERS[ability.Kind] ~= nil,
		`kind "{ability.Kind}" has no resolver`
	)

	assert(
		ability.Cooldown >= 0,
		`ability "{abilityId}" has invalid cooldown`
	)

	assert(
		ability.Commit >= 0,
		`ability "{abilityId}" has invalid commit duration`
	)

	for _, field in required do
		assert(
			(ability :: any)[field] ~= nil,
			`ability "{abilityId}" missing field "{field}"`
		)
	end
end

--== EXECUTION PIPELINE ===============================================

function CombatService:Execute(
	player: Player,
	abilityId: any,
	rawDirection: any
): (boolean, string)
	-- Cheapest validation happens first. A malicious caller should have to
	-- spend server CPU on physics only after it survives the inexpensive
	-- structural checks.
	if type(abilityId) ~= "string" then
		return false, "BadRequest"
	end

	local ability = ABILITIES[abilityId]

	if not ability then
		local state = self._players:Get(player)

		if state then
			return self:_reject(
				state,
				abilityId,
				"UnknownAbility"
			)
		end

		return false, "UnknownAbility"
	end

	local state =
		self._players:Get(player)

	if not state then
		return false, "NoState"
	end

	if not state.loadout[abilityId] then
		return self:_reject(
			state,
			abilityId,
			"NotOwned"
		)
	end

	if not self._players:ConsumeToken(state) then
		return self:_reject(
			state,
			abilityId,
			"Throttled"
		)
	end

	local direction =
		sanitizeDirection(rawDirection)

	if not direction then
		return self:_reject(
			state,
			abilityId,
			"BadAim"
		)
	end

	-- Cached Instance references may become invalid during respawn. Both the
	-- existence and health checks are therefore required before any resolver.
	local humanoid = state.humanoid

	if not (
		state.character
		and state.root
		and humanoid
	)
	then
		return self:_reject(
			state,
			abilityId,
			"NotAlive"
		)
	end

	if humanoid.Health <= 0 then
		return self:_reject(
			state,
			abilityId,
			"NotAlive"
		)
	end

	if state.name ~= "Ready" then
		return self:_reject(
			state,
			abilityId,
			"Busy"
		)
	end

	local now = os.clock()
	local readyAt =
		state.cooldowns[abilityId]

	if readyAt and now < readyAt then
		return self:_reject(
			state,
			abilityId,
			"Cooldown"
		)
	end

	-- Mobility is intentionally grounded. This restriction is enforced before
	-- the impulse, so the server never has to repair an impossible post-launch
	-- position afterward.
	if ability.Kind == "Mobility"
		and humanoid.FloorMaterial
			== Enum.Material.Air
	then
		return self:_reject(
			state,
			abilityId,
			"Airborne"
		)
	end

	-- Commit before resolving. If the resolver throws, the ability cannot simply
	-- be re-entered on the following frame. This preserves state consistency
	-- even when an integration point fails unexpectedly.
	state.cooldowns[abilityId] =
		now + ability.Cooldown

	local committedState =
		if ability.Kind == "Mobility"
		then "Dashing"
		else "Committed"

	self._players:SetState(
		state,
		committedState,
		ability.Commit
	)

	local resolver =
		RESOLVERS[ability.Kind]

	if not resolver then
		return self:_reject(
			state,
			abilityId,
			"MissingResolver"
		)
	end

	local ok, result =
		pcall(
			resolver,
			self,
			state,
			ability,
			direction
		)

	if not ok then
		warn(
			`[Arcline/Combat] resolver failed `
			.. `for {player.Name}: {result}`
		)

		self:_notify(
			player,
			abilityId,
			false,
			0,
			"InternalError"
		)

		return false, "InternalError"
	end

	local hits = tonumber(result) or 0

	self.AbilityExecuted:Fire(
		player,
		abilityId,
		hits
	)

	self:_notify(
		player,
		abilityId,
		true,
		hits,
		"Ok"
	)

	return true, "Ok"
end

--== TOOL DEMONSTRATION ===============================================

function CombatService:_giveTools(
	player: Player
)
	local backpack =
		player:WaitForChild(
			"Backpack",
			5
		)

	local state =
		self._players:Get(player)

	if not (
		backpack
		and state
		and state.characterBin
	)
	then
		return
	end

	for _, abilityId in ABILITY_ORDER do
		if not state.loadout[abilityId] then
			continue
		end

		if backpack:FindFirstChild(abilityId) then
			continue
		end

		local tool = Instance.new("Tool")
		tool.Name = abilityId
		tool.RequiresHandle = false
		tool.CanBeDropped = false
		tool.ToolTip =
			`Server-authoritative {abilityId}`

		local activationConnection =
			tool.Activated:Connect(function()
				local current =
					self._players:Get(player)

				local root =
					current and current.root

				if root then
					-- The tool event identifies the player but provides no trusted
					-- combat result. The same Execute() function still performs
					-- every validation and server-side calculation.
					self:Execute(
						player,
						abilityId,
						root.CFrame.LookVector
					)
				end
			end)

		tool.Parent = backpack

		state.characterBin:Add(tool)
		state.characterBin:Add(activationConnection)
	end
end

function CombatService:Start()
	local net = ensureChild(
		ReplicatedStorage,
		"Folder",
		"ArclineNet"
	) :: Folder

	self._net = net

	local request = ensureChild(
		net,
		"RemoteEvent",
		"AbilityRequest"
	) :: RemoteEvent

	local loadout = ensureChild(
		net,
		"RemoteFunction",
		"QueryLoadout"
	) :: RemoteFunction

	local feedback = ensureChild(
		net,
		"RemoteEvent",
		"CombatFeedback"
	) :: RemoteEvent

	self._feedback = feedback

	self._bin:Add(
		request.OnServerEvent:Connect(
			function(
				player: Player,
				abilityId: any,
				direction: any
			)
				-- Remote arguments are attacker-controlled by definition. The
				-- network handler therefore remains a thin transport layer and
				-- delegates all security decisions to Execute().
				self:Execute(
					player,
					abilityId,
					direction
				)
			end
		)
	)

	loadout.OnServerInvoke =
		function(caller: Player)
			local state =
				self._players:Get(caller)

			if not state then
				return nil
			end

			if not self._players:ConsumeToken(state) then
				self:_reject(
					state,
					"QueryLoadout",
					"Throttled"
				)

				return nil
			end

			local now = os.clock()

			local reply: {
				[string]: number,
			} = {}

			-- Iterating the known order rather than arbitrary dictionary keys makes
			-- the remote response deterministic and keeps the exposed set limited
			-- to configured abilities owned by this player.
			for _, abilityId in ABILITY_ORDER do
				if state.loadout[abilityId] then
					reply[abilityId] = math.max(
						0,
						(state.cooldowns[abilityId] or 0)
							- now
					)
				end
			end

			return reply
		end

	self._bin:Add(
		self._players.CharacterReady:Connect(
			function(player: Player)
				self:_giveTools(player)
			end
		)
	)

	self._bin:Add(
		self._players.StateChanged:Connect(
			function(
				player: Player,
				current: string
			)
				local state =
					self._players:Get(player)

				local humanoid =
					state and state.humanoid

				if not humanoid then
					return
				end

				humanoid.WalkSpeed =
					if current == "Committed"
					then CONFIG.CommittedWalkSpeed
					else CONFIG.BaseWalkSpeed
			end
		)
	)
end

function CombatService:Shutdown()
	self._bin:Destroy()

	self.DamageDealt:Destroy()
	self.RequestRejected:Destroy()
	self.AbilityExecuted:Destroy()
end

Framework.Register(CombatService)

--== TELEMETRY SERVICE ================================================

local TelemetryService = {
	Name = "Telemetry",

	_players = nil :: any,
	_combat = nil :: any,

	_bin = Bin.new(),
}

function TelemetryService:Init()
	self._players =
		Framework.Get("PlayerState")

	self._combat =
		Framework.Get("Combat")
end

function TelemetryService:Start()
	self._bin:Add(
		self._combat.DamageDealt:Connect(
			function(
				player: Player,
				humanoid: Humanoid,
				damage: number
			)
				local state =
					self._players:Get(player)

				if not state then
					return
				end

				-- Accumulate the actual floating-point damage and only round for
				-- display. Rounding each hit before accumulation would gradually
				-- diverge from the real combat value when falloff produces fractions.
				state.damageDealt += damage

				if state.damageValue then
					state.damageValue.Value =
						math.floor(
							state.damageDealt
						)
				end

				if humanoid.Health <= 0 then
					local victim =
						humanoid.Parent

					print(
						`[Arcline] {player.Name} `
						.. `eliminated `
						.. `{victim and victim.Name or "?"}`
					)
				end
			end
		)
	)

	self._bin:Add(
		self._combat.RequestRejected:Connect(
			function(
				player: Player,
				abilityId: string,
				reason: string
			)
				local state =
					self._players:Get(player)

				local rejected =
					state and state.rejected
					or 0

				warn(
					`[Arcline/Combat] rejected `
					.. `{abilityId} from {player.Name}: `
					.. `{reason} `
					.. `(total {rejected})`
				)
			end
		)
	)

	self._bin:Add(
		self._combat.AbilityExecuted:Connect(
			function(
				player: Player,
				abilityId: string,
				hits: number
			)
				print(
					`[Arcline] {player.Name} `
					.. `executed {abilityId} `
					.. `(hits={hits})`
				)
			end
		)
	)
end

function TelemetryService:Shutdown()
	self._bin:Destroy()
end

Framework.Register(TelemetryService)

--== DEMONSTRATION ARENA ==============================================

local DemoService = {
	Name = "Demo",

	_bin = Bin.new(),
}

local function createTrainingTarget(
	position: Vector3,
	index: number
): Model
	local model = Instance.new("Model")
	model.Name = `TrainingTarget_{index}`

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2.5, 4, 2.5)
	root.Position = position
	root.Anchored = true
	root.CanCollide = true
	root.Color = Color3.fromRGB(
		120 + (index * 12) % 100,
		70,
		70
	)
	root.Parent = model

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 2, 2)
	head.Position =
		position + Vector3.yAxis * 3
	head.Anchored = true
	head.CanCollide = false
	head.Parent = model

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.DisplayName =
		`Target {index}`
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = Workspace

	return model
end

local function createArena()
	local oldArena =
		Workspace:FindFirstChild("ArclineDemo")

	if oldArena then
		oldArena:Destroy()
	end

	local arena = Instance.new("Folder")
	arena.Name = "ArclineDemo"
	arena.Parent = Workspace

	local floor = Instance.new("Part")
	floor.Name = "ArenaFloor"
	floor.Size = Vector3.new(
		CONFIG.ArenaSize,
		1,
		CONFIG.ArenaSize
	)
	floor.Position = Vector3.new(
		0,
		-0.5,
		0
	)
	floor.Anchored = true
	floor.Material = Enum.Material.Concrete
	floor.Color = Color3.fromRGB(
		38,
		40,
		44
	)
	floor.Parent = arena

	local wallThickness = 2
	local half =
		CONFIG.ArenaSize * 0.5

	local walls = {
		{
			Size = Vector3.new(
				CONFIG.ArenaSize,
				CONFIG.ArenaWallHeight,
				wallThickness
			),

			Position = Vector3.new(
				0,
				CONFIG.ArenaWallHeight * 0.5,
				-half
			),
		},

		{
			Size = Vector3.new(
				CONFIG.ArenaSize,
				CONFIG.ArenaWallHeight,
				wallThickness
			),

			Position = Vector3.new(
				0,
				CONFIG.ArenaWallHeight * 0.5,
				half
			),
		},

		{
			Size = Vector3.new(
				wallThickness,
				CONFIG.ArenaWallHeight,
				CONFIG.ArenaSize
			),

			Position = Vector3.new(
				-half,
				CONFIG.ArenaWallHeight * 0.5,
				0
			),
		},

		{
			Size = Vector3.new(
				wallThickness,
				CONFIG.ArenaWallHeight,
				CONFIG.ArenaSize
			),

			Position = Vector3.new(
				half,
				CONFIG.ArenaWallHeight * 0.5,
				0
			),
		},
	}

	for index, wallData in walls do
		local wall = Instance.new("Part")
		wall.Name = `ArenaWall_{index}`
		wall.Size = wallData.Size
		wall.Position = wallData.Position
		wall.Anchored = true
		wall.Material = Enum.Material.Slate
		wall.Color = Color3.fromRGB(
			25,
			27,
			31
		)
		wall.Parent = arena
	end

	for index = 1, CONFIG.TrainingTargetCount do
		local column =
			(index - 1) % 3

		local row =
			math.floor((index - 1) / 3)

		local position = Vector3.new(
			-18 + column * CONFIG.TrainingTargetSpacing,
			2.5,
			24 + row * CONFIG.TrainingTargetSpacing
		)

		createTrainingTarget(
			position,
			index
		)
	end

	-- A small center platform gives the mobility ability a visible point of
	-- reference while still leaving enough open space for the ray and arc tests.
	local platform = Instance.new("Part")
	platform.Name = "CenterPlatform"
	platform.Size = Vector3.new(
		22,
		2,
		22
	)
	platform.Position = Vector3.new(
		0,
		1,
		-20
	)
	platform.Anchored = true
	platform.Material = Enum.Material.Metal
	platform.Color = Color3.fromRGB(
		55,
		60,
		68
	)
	platform.Parent = arena
end

function DemoService:Start()
	createArena()
end

function DemoService:Shutdown()
	self._bin:Destroy()

	local arena =
		Workspace:FindFirstChild("ArclineDemo")

	if arena then
		arena:Destroy()
	end

	local debug =
		Workspace:FindFirstChild("ArclineDebug")

	if debug then
		debug:Destroy()
	end
end

Framework.Register(DemoService)

--== BOOTSTRAP ========================================================

Framework.Ignite()

print(
	`[Arcline] combat online`
	.. ` | abilities: `
	.. table.concat(
		ABILITY_ORDER,
		", "
	)
)

print(
	"[Arcline] demo arena created; "
	.. "equip Cleave, Bolt or Lunge to test "
	.. "the server-authoritative execution path."
)

-- The framework remains capable of a full shutdown for Studio/plugin style
-- lifecycles. The actual server process normally owns its lifetime, so there
-- is intentionally no Heartbeat polling here solely to detect termination.
