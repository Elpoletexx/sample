-- Connected Discord-GitHub
--!strict

--[[
	ARCLINE COMBAT — a server-authoritative ability system in a single script.

	The rule the whole file is built around: a client may ask for an ability and
	hand over an aim direction. It never supplies an origin, a target, a hit
	list, a damage number or a cooldown, because those are exactly the values a
	modified client forges first. Every decision below follows from that.

	It is deliberately one file, and it provisions its own remotes and tools on
	Start(), so it runs in an empty baseplate with no companion scripts.
	Internally it is still layered the way I build multi-module places: a frozen
	config block, two small primitives (Signal, Bin) and three services behind an
	explicit Init/Start lifecycle.

	Public demonstration code. It shares design principles with my private
	framework but contains none of its source.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--== CONFIGURATION ====================================================

local CONFIG = {
	-- A per-ability cooldown stops the *ability*, not the packet. The token
	-- bucket bounds what a flood costs the server, and it refills lazily on
	-- request instead of on a timer, so idle players cost exactly nothing.
	BucketSize = 8,
	BucketRefillPerSecond = 5,

	-- Capping pitch closes the cheapest way to turn a legitimate ability into a
	-- wallhack: aiming straight down at somebody standing under the floor.
	MaxAimPitch = 0.72,

	-- Every impulse we write is clamped. Uncapped knockback is a free "launch a
	-- player out of the map" exploit the moment two sources stack in one frame.
	MaxImpulse = 110,
	KnockbackLift = 0.35,

	-- Bounds the work one swing can force on the broadphase query, so an attack
	-- costs the same whether the arena holds two players or forty.
	MaxQueryParts = 64,
	ArcVerticalTolerance = 7,

	-- Committing to a swing costs mobility. Global feel, not per-ability data.
	BaseWalkSpeed = 16,
	CommittedWalkSpeed = 7,
}
table.freeze(CONFIG)

--== ABILITY DATA =====================================================

-- Optional fields are the ones a Kind is responsible for; the load-time
-- check further down is what turns "optional in the type" into
-- "guaranteed for this Kind" before any resolver reads them.
type Ability = {
	Kind: string, Cooldown: number, Commit: number,
	Damage: number?, Range: number?, ArcCosine: number?, Falloff: number?,
	Knockback: number?, Impulse: number?, Lift: number?,
}

-- Abilities are data, not code paths. Adding one is a table entry plus a Kind
-- that already has a resolver — the difference between a system and a pile of
-- if-statements that grows every time a designer asks for a variant.
local ABILITIES: { [string]: Ability } = {
	-- ArcCosine is cos(65°) precomputed: the cone test is then one divide
	-- and one compare per candidate, not an inverse-trig call per part.
	Cleave = {
		Kind = "Arc", Cooldown = 0.75, Commit = 0.30,
		Damage = 16, Range = 12, ArcCosine = 0.4226, Knockback = 38,
	},
	-- Falloff is the damage retained at maximum range: without it a
	-- hitscan ability makes every other range bracket in the kit pointless.
	Bolt = {
		Kind = "Ray", Cooldown = 1.5, Commit = 0.22,
		Damage = 27, Range = 95, Falloff = 0.45, Knockback = 26,
	},
	Lunge = {
		Kind = "Mobility", Cooldown = 3.5, Commit = 0.40,
		Impulse = 82, Lift = 22,
	},
}

-- Hotbar order is explicit because `pairs` order is not stable, and a loadout
-- that shuffles its slots between servers is a bug players feel immediately.
local ABILITY_ORDER = { "Cleave", "Bolt", "Lunge" }

-- table.freeze is shallow, so the nested tables are frozen too: a stray write
-- to shared config at runtime would otherwise silently rebalance the game for
-- every player on the server, with no error to trace it back to.
for _, ability in ABILITIES do
	table.freeze(ability)
end
table.freeze(ABILITIES)
table.freeze(ABILITY_ORDER)

--== SIGNAL ===========================================================

type SignalSlot = { fn: (...any) -> (), alive: boolean }

local Signal = {}
Signal.__index = Signal

type Signal = typeof(setmetatable({} :: {
	_slots: { SignalSlot },
	_depth: number,
	_dirty: boolean,
}, Signal))

function Signal.new(): Signal
	return setmetatable({ _slots = {}, _depth = 0, _dirty = false }, Signal)
end

function Signal:Connect(handler: (...any) -> ()): { Disconnect: () -> () }
	assert(type(handler) == "function", "Signal handler must be a function")
	local slot: SignalSlot = { fn = handler, alive = true }
	table.insert(self._slots, slot)

	-- Disconnect flags the slot instead of removing it. A listener is allowed
	-- to disconnect itself or a sibling mid-dispatch, and removing from the
	-- array we are iterating shifts the tail and silently skips the very next
	-- listener — a bug that only appears under load. Compaction is deferred
	-- until no dispatch is left on the stack.
	return {
		Disconnect = function()
			if not slot.alive then return end
			slot.alive = false
			self._dirty = true
			if self._depth == 0 then self:_compact() end
		end,
	}
end

function Signal:Fire(...)
	self._depth += 1
	local slots = self._slots
	for index = 1, #slots do
		local slot = slots[index]
		-- Listeners are foreign code. Giving each its own thread means one that
		-- errors or yields cannot unwind or stall the combat call that fired
		-- the signal, while the error still reaches output instead of being
		-- swallowed by a pcall.
		if slot.alive then task.spawn(slot.fn, ...) end
	end
	self._depth -= 1
	if self._depth == 0 and self._dirty then self:_compact() end
end

function Signal:_compact()
	local slots = self._slots
	for index = #slots, 1, -1 do
		if not slots[index].alive then table.remove(slots, index) end
	end
	self._dirty = false
end

--== BIN — ownership-scoped cleanup ===================================

local Bin = {}
Bin.__index = Bin

type Bin = typeof(setmetatable({} :: { _items: { any } }, Bin))

function Bin.new(): Bin
	return setmetatable({ _items = {} }, Bin)
end

-- Everything a player owns is added at the moment it is created, so cleanup
-- stops being a checklist somebody has to keep in sync with the constructor:
-- if it was never added to a bin it was never created, and one Destroy() call
-- drops the whole graph.
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
		-- The escape hatch: anything with a stranger shape is added as a
		-- closure that knows how to undo itself, which keeps this dispatch
		-- from growing a branch per resource type.
		item()
	elseif kind == "table" and type(item.Disconnect) == "function" then
		-- Signal handles, so a bin can own a subscription the same way it
		-- owns an Instance. Keeping this branch is what stops Signal and
		-- Bin from drifting into two cleanup models that disagree.
		item:Disconnect()
	else
		-- Warn rather than no-op: a bin that silently ignores an item is a
		-- leak that looks exactly like working cleanup.
		warn(`[Arcline/Bin] no disposer for {kind}`)
	end
end

function Bin:Destroy()
	local items = self._items
	-- Reverse order, because later items were built on top of earlier ones: a
	-- tool's Activated connection is only meaningful while the tool exists.
	for index = #items, 1, -1 do
		local item = items[index]
		items[index] = nil
		-- One failed disposal must not strand the rest of the bin; a
		-- half-cleaned player is a leak that outlives the whole server session.
		local ok, err = pcall(disposeItem, item)
		if not ok then warn(`[Arcline/Bin] dispose failed: {err}`) end
	end
end

--== PLAYER STATE SHAPE ===============================================

-- `loadout` is a set, not an array: the only question ever asked is "does
-- this player own it", and a client-supplied index into an array is one
-- more thing to bounds-check for no benefit. The Instance fields are
-- optional because a player is characterless between death and respawn,
-- which the type then forces every caller to acknowledge.
type PlayerState = {
	player: Player, bin: Bin, characterBin: Bin?,
	name: string, expiresAt: number,
	tokens: number, lastRefill: number,
	cooldowns: { [string]: number },
	loadout: { [string]: boolean },
	character: Model?, humanoid: Humanoid?, root: BasePart?,
	damageDealt: number, rejected: number, damageValue: IntValue?,
}

--== SERVICE LIFECYCLE ================================================

local Framework = {
	_services = {} :: { [string]: any },
	_order = {} :: { any },
}

function Framework.Register(service: any)
	local name = assert(service.Name, "service is missing a Name")
	assert(Framework._services[name] == nil, `duplicate service: {name}`)
	Framework._services[name] = service
	table.insert(Framework._order, service)
end

function Framework.Get(name: string): any
	return assert(Framework._services[name], `unknown service: {name}`)
end

-- Two passes, on purpose. Init() may resolve references to siblings and build a
-- service's own state; Start() may use them, subscribe to their signals and
-- touch the DataModel. That split is what makes declaration order irrelevant:
-- by the time any Start() runs, every service exists and is fully constructed,
-- so the whole "service A grabbed B's signal before B created it" class of bug
-- cannot happen — the only reason a registry earns its place in one file.
function Framework.Ignite()
	for _, service in Framework._order do
		if service.Init then service:Init() end
	end
	for _, service in Framework._order do
		if service.Start then service:Start() end
	end
end

--== SHARED HELPERS ===================================================

-- The only value a client is allowed to influence, and therefore the only one
-- that needs a real parser rather than a type check.
local function sanitizeDirection(value: any): Vector3?
	if typeof(value) ~= "Vector3" then return nil end

	-- NaN survives every naive guard: it compares false against everything
	-- including itself, it propagates through .Unit, and it only surfaces later
	-- as a hard error inside CFrame.lookAt, deep in the hit query. Catching it
	-- at the boundary keeps the failure reportable and countable.
	if value ~= value then return nil end

	local magnitude = value.Magnitude
	if magnitude < 1e-3 or magnitude > 1e6 then return nil end

	-- An arc and a ray both need horizontal facing. A purely vertical vector has
	-- none, so it is rejected rather than snapped to some default the player
	-- never aimed at.
	local unit = value.Unit
	if math.abs(unit.X) < 1e-4 and math.abs(unit.Z) < 1e-4 then return nil end

	local pitch = math.clamp(unit.Y, -CONFIG.MaxAimPitch, CONFIG.MaxAimPitch)
	return Vector3.new(unit.X, pitch, unit.Z).Unit
end

local function clampImpulse(impulse: Vector3): Vector3
	local magnitude = impulse.Magnitude
	if magnitude > CONFIG.MaxImpulse then
		return impulse * (CONFIG.MaxImpulse / magnitude)
	end
	return impulse
end

-- A hit part is almost never the character itself: it is an accessory mesh, a
-- tool handle or a limb. Walking up to the owning model and asking it for a
-- Humanoid is what makes hit detection work against real R6/R15 rigs. The
-- caster is excluded at the query level instead of here, because a filter that
-- never returns the parts is cheaper than a comparison that discards them.
local function resolveTarget(part: BasePart): (Model?, Humanoid?, BasePart?)
	local model = part:FindFirstAncestorOfClass("Model") :: Model?
	while model do
		local humanoid = model:FindFirstChildOfClass("Humanoid") :: any
		if humanoid then
			if humanoid.Health <= 0 then return nil, nil, nil end
			local root = (model.PrimaryPart or model:FindFirstChild("HumanoidRootPart")) :: any
			return model, humanoid, root
		end
		-- Nested models are common on real rigs (accessories, tool models),
		-- so the walk continues upwards instead of giving up at the first
		-- Model that happens to have no Humanoid of its own.
		model = model:FindFirstAncestorOfClass("Model") :: Model?
	end
	return nil, nil, nil
end

-- Provisioning is idempotent so a re-run in Studio cannot leave duplicate
-- remotes behind, and so the network contract is created by the code that
-- serves it rather than authored by hand in a tree that can drift.
local function ensureChild(parent: Instance, className: string, name: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then return existing end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = parent
	return instance
end

--== PLAYER STATE SERVICE =============================================

local PlayerStateService = {
	Name = "PlayerState",
	StateChanged = Signal.new(),
	CharacterReady = Signal.new(),
	_states = {} :: { [Player]: PlayerState },
}

-- The legal edges live in data rather than in an if-chain scattered through the
-- combat code. A request that arrives mid-commit is then rejected by a single
-- table lookup, and adding a state later cannot silently open a transition
-- nobody reviewed — the illegal edges are the interesting ones.
local STATE_RULES: { [string]: { [string]: boolean } } = {
	Ready = { Committed = true, Dashing = true, Downed = true },
	Committed = { Ready = true, Downed = true },
	Dashing = { Ready = true, Downed = true },
	Downed = { Ready = true },
}

function PlayerStateService:Get(player: Player): PlayerState?
	return self._states[player]
end

function PlayerStateService:SetState(state: PlayerState, name: string, duration: number?): boolean
	if state.name == name then return true end
	local allowed = STATE_RULES[state.name]
	if not (allowed and allowed[name]) then return false end

	state.name = name
	-- os.clock() rather than os.time()/tick(): it is a monotonic process clock,
	-- so a wall-clock correction on the machine cannot make a cooldown expire
	-- early or hang forever.
	state.expiresAt = if duration then os.clock() + duration else 0
	self.StateChanged:Fire(state.player, name)
	return true
end

function PlayerStateService:ConsumeToken(state: PlayerState): boolean
	local now = os.clock()
	local elapsed = now - state.lastRefill
	if elapsed > 0 then
		state.lastRefill = now
		state.tokens = math.min(CONFIG.BucketSize, state.tokens + elapsed * CONFIG.BucketRefillPerSecond)
	end
	if state.tokens < 1 then return false end
	state.tokens -= 1
	return true
end

function PlayerStateService:_bindCharacter(state: PlayerState, character: Model)
	if state.characterBin then state.characterBin:Destroy() end
	local bin = Bin.new()
	state.characterBin = bin

	-- A timeout instead of an unbounded WaitForChild: a character can be
	-- destroyed while we wait (fast respawn, player leaving), and an infinite
	-- wait would pin this thread and the whole character graph in memory.
	local humanoid: Humanoid? = character:WaitForChild("Humanoid", 5) :: any
	local root: BasePart? = character:WaitForChild("HumanoidRootPart", 5) :: any

	if not (humanoid and root) then return end
	-- Re-check identity after yielding: by now the player may already be on
	-- their next character, and caching a stale one would aim every
	-- ability at a corpse for the rest of that life.
	if state.player.Character ~= character then return end

	state.character = character
	state.humanoid = humanoid
	state.root = root
	state.name = "Ready"
	state.expiresAt = 0

	-- Cooldowns describe a body that no longer exists, so they are cleared on
	-- respawn. The loadout is not: that is progression, and wiping it on death
	-- would be a data bug dressed up as a balance decision.
	table.clear(state.cooldowns)

	bin:Add(humanoid.Died:Connect(function()
		-- Death is the one transition that ignores the rule table: it can
		-- interrupt any state. Clearing the cached instances here is what makes
		-- every in-flight ability fail its liveness check instead of resolving
		-- against a dead rig.
		state.name = "Downed"
		state.expiresAt = 0
		state.character, state.humanoid, state.root = nil, nil, nil
	end))

	self.CharacterReady:Fire(state.player, character)
end

function PlayerStateService:_onPlayerAdded(player: Player)
	-- The Instance fields are left absent rather than written as nil: in
	-- Lua that is the same table, and spelling them out would suggest the
	-- record is complete before a character has ever loaded.
	local state: PlayerState = {
		player = player,
		bin = Bin.new(),
		name = "Ready",
		expiresAt = 0,
		tokens = CONFIG.BucketSize,
		lastRefill = os.clock(),
		cooldowns = {},
		loadout = { Cleave = true, Bolt = true, Lunge = true },
		damageDealt = 0,
		rejected = 0,
	}
	self._states[player] = state

	-- leaderstats is the cheapest honest readout for a demo: the number on the
	-- player list is the server's own damage total, so validation and scoring
	-- can be watched agreeing with each other without a line of UI code.
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local damage = Instance.new("IntValue")
	damage.Name = "Damage"
	damage.Parent = stats
	stats.Parent = player
	state.damageValue = damage
	state.bin:Add(stats)

	state.bin:Add(player.CharacterAdded:Connect(function(character)
		self:_bindCharacter(state, character)
	end))
	if player.Character then self:_bindCharacter(state, player.Character) end
end

function PlayerStateService:Start()
	Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end)

	-- A player can already be in the game by the time a server script finishes
	-- loading — Studio's Play Solo does exactly this — so the join handler is
	-- replayed over the current list instead of being trusted to have fired.
	-- task.spawn because _bindCharacter yields on WaitForChild.
	for _, player in Players:GetPlayers() do
		task.spawn(function()
			self:_onPlayerAdded(player)
		end)
	end

	Players.PlayerRemoving:Connect(function(player)
		local state = self._states[player]
		if not state then return end
		if state.characterBin then state.characterBin:Destroy() end
		state.bin:Destroy()
		-- The map is keyed by the Player instance: leaving the entry behind
		-- keeps the player, its character and every part it touched reachable
		-- for the lifetime of the server.
		self._states[player] = nil
	end)

	-- One Heartbeat for the whole server instead of a task.delay per swing. A
	-- timer thread per attack cannot be cancelled when the caster dies
	-- mid-recovery, so it would resurrect a stale state a frame later; this
	-- sweep reads current truth every frame and costs one compare per idle player.
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for _, state in self._states do
			if state.expiresAt > 0 and now >= state.expiresAt then
				state.expiresAt = 0
				if state.name ~= "Downed" then self:SetState(state, "Ready") end
			end
		end
	end)
end

Framework.Register(PlayerStateService)

--== COMBAT SERVICE ===================================================

local CombatService = {
	Name = "Combat",
	DamageDealt = Signal.new(),
	RequestRejected = Signal.new(),
	_players = nil :: any,
	_feedback = nil :: any,
}

local RESOLVERS: { [string]: (any, PlayerState, Ability, Vector3) -> number }

function CombatService:Init()
	-- Resolved in Init, used in Start: the half of the lifecycle contract that
	-- lets services be declared in any order.
	self._players = Framework.Get("PlayerState")
end

function CombatService:_applyHit(state: PlayerState, ability: Ability, humanoid: Humanoid, targetRoot: BasePart?, push: Vector3, damage: number)
	-- TakeDamage rather than writing Health directly: it honours ForceFields, so
	-- spawn protection keeps working for free, and the value it receives is
	-- always derived from the frozen config — the client never names a number.
	humanoid:TakeDamage(damage)

	local knockback = ability.Knockback
	if targetRoot and knockback then
		local flat = Vector3.new(push.X, 0, push.Z)
		if flat.Magnitude > 1e-3 then
			-- A one-shot velocity, not a constraint: the victim's assembly is
			-- network-owned by their own client, so a constraint would be
			-- simulated there anyway and would still need cleaning up if they
			-- died mid-push. The clamp keeps stacked hits from becoming a launch.
			local impulse = flat.Unit * knockback + Vector3.yAxis * (knockback * CONFIG.KnockbackLift)
			targetRoot.AssemblyLinearVelocity = clampImpulse(impulse)
		end
	end

	self.DamageDealt:Fire(state.player, humanoid, damage)
end

function CombatService:_resolveArc(state: PlayerState, ability: Ability, direction: Vector3): number
	local root = state.root :: BasePart
	local origin = root.Position
	local facing = CFrame.lookAt(origin, origin + direction)
	local range = ability.Range :: number

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { state.character :: Instance }
	params.MaxParts = CONFIG.MaxQueryParts

	-- One character contributes a dozen parts to a radius query, so the *model*
	-- is the unit of a hit, not the part. Without this set a single swing would
	-- apply its damage once per limb.
	local struck: { [Model]: boolean } = {}
	local hits = 0

	for _, part in Workspace:GetPartBoundsInRadius(origin, range, params) do
		local model, humanoid, targetRoot = resolveTarget(part)
		if model and humanoid and targetRoot and not struck[model] then
			-- The cone test runs in the attacker's own space rather than with
			-- world vectors: PointToObjectSpace yields forward distance and
			-- lateral offset in one transform, so the check is a divide and two
			-- compares. Height is tested separately from the arc so that
			-- widening the cone never lets a ground swing reach a rooftop.
			local offset = facing:PointToObjectSpace(targetRoot.Position)
			local forward = -offset.Z
			if forward > 0 and math.abs(offset.Y) <= CONFIG.ArcVerticalTolerance then
				local flat = math.sqrt(offset.X * offset.X + offset.Z * offset.Z)
				if flat > 0 and (forward / flat) >= (ability.ArcCosine :: number) then
					struck[model] = true
					hits += 1
					self:_applyHit(state, ability, humanoid, targetRoot, targetRoot.Position - origin, ability.Damage :: number)
				end
			end
		end
	end

	return hits
end

function CombatService:_resolveRay(state: PlayerState, ability: Ability, direction: Vector3): number
	local root = state.root :: BasePart
	-- Lifted to chest height so the ray does not begin inside the floor the
	-- root is standing on, which would make every shot hit the ground.
	local origin = root.Position + Vector3.yAxis * 1.5
	local range = ability.Range :: number

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { state.character :: Instance }
	params.IgnoreWater = true

	local result = Workspace:Raycast(origin, direction * range, params)
	if not result then return 0 end

	local _model, humanoid, targetRoot = resolveTarget(result.Instance)
	-- The ray stopped on geometry. The cooldown was already spent at commit
	-- time and is deliberately not refunded: refunding a miss would make
	-- spraying the ability into a wall strictly better than aiming it.
	if not humanoid then return 0 end

	-- Falloff is measured from the real impact point rather than from the
	-- requested range — the client does not get to decide how far its own shot
	-- travelled, only which way it pointed.
	local travelled = (result.Position - origin).Magnitude
	local ratio = math.clamp(travelled / range, 0, 1)
	local damage = (ability.Damage :: number) * (1 - ratio * (1 - (ability.Falloff :: number)))

	self:_applyHit(state, ability, humanoid, targetRoot, direction, damage)
	return 1
end

function CombatService:_resolveMobility(state: PlayerState, ability: Ability, direction: Vector3): number
	local root = state.root :: BasePart
	root.AssemblyLinearVelocity = clampImpulse(direction * (ability.Impulse :: number) + Vector3.yAxis * (ability.Lift :: number))
	return 0
end

RESOLVERS = {
	Arc = CombatService._resolveArc,
	Ray = CombatService._resolveRay,
	Mobility = CombatService._resolveMobility,
}

-- Config is validated once at load instead of trusted. A missing field or a
-- typo in a Kind would otherwise surface as an arithmetic-on-nil error the
-- first time a player pressed that button in a live server — and this check is
-- also what makes the `:: number` casts in the resolvers honest rather than hopeful.
local REQUIRED_FIELDS: { [string]: { string } } = {
	Arc = { "Damage", "Range", "ArcCosine", "Knockback" },
	Ray = { "Damage", "Range", "Falloff", "Knockback" },
	Mobility = { "Impulse", "Lift" },
}

for abilityId, ability in ABILITIES do
	local required = assert(REQUIRED_FIELDS[ability.Kind], `ability "{abilityId}" has unknown kind "{ability.Kind}"`)
	assert(RESOLVERS[ability.Kind], `kind "{ability.Kind}" has no resolver`)
	for _, field in required do
		assert((ability :: any)[field] ~= nil, `ability "{abilityId}" is missing field "{field}"`)
	end
end

function CombatService:_notify(player: Player, abilityId: string, accepted: boolean, hits: number, reason: string)
	-- A request can still be in flight when the player leaves.
	if not player.Parent then return end
	-- FireClient, never FireAllClients: nobody else has any use for another
	-- player's rejection reasons, and an unnecessary broadcast is bandwidth
	-- multiplied by the whole server population. The reply shape is fixed so
	-- the client handler never has to type-switch on its arguments.
	self._feedback:FireClient(player, abilityId, accepted, hits, reason)
end

function CombatService:_reject(state: PlayerState, abilityId: string, reason: string): (boolean, string)
	state.rejected += 1
	self.RequestRejected:Fire(state.player, abilityId, reason)
	self:_notify(state.player, abilityId, false, 0, reason)
	return false, reason
end

-- The single validated entry point. Both front-ends — the RemoteEvent a real
-- client would use and the Tools this demo hands out — funnel through here,
-- because validation belongs to the service, not to whichever transport
-- happened to deliver the request. Checks are ordered cheapest-first and bail
-- on the first failure, so the work a spamming client can force is a table
-- lookup, never a physics query.
function CombatService:Execute(player: Player, abilityId: any, rawDirection: any): (boolean, string)
	if type(abilityId) ~= "string" then return false, "BadRequest" end
	local ability = ABILITIES[abilityId]
	if not ability then return false, "UnknownAbility" end

	local state = self._players:Get(player)
	if not state then return false, "NoState" end
	if not state.loadout[abilityId] then return self:_reject(state, abilityId, "NotOwned") end
	if not self._players:ConsumeToken(state) then return self:_reject(state, abilityId, "Throttled") end

	local direction = sanitizeDirection(rawDirection)
	if not direction then return self:_reject(state, abilityId, "BadAim") end

	-- Liveness is two questions, not one: the cached instances can be gone
	-- (dead between respawning) or present but at zero health for the
	-- frame between TakeDamage and Died firing.
	local humanoid = state.humanoid
	if not (state.character and state.root and humanoid) then
		return self:_reject(state, abilityId, "NotAlive")
	end
	if humanoid.Health <= 0 then return self:_reject(state, abilityId, "NotAlive") end
	if state.name ~= "Ready" then return self:_reject(state, abilityId, "Busy") end

	local now = os.clock()
	local readyAt = state.cooldowns[abilityId]
	if readyAt and now < readyAt then return self:_reject(state, abilityId, "Cooldown") end

	-- A grounded-only dash removes the "stack the impulse in mid-air to reach
	-- anywhere on the map" exploit at the source, instead of trying to catch
	-- the resulting position with a height check somewhere else.
	if ability.Kind == "Mobility" and humanoid.FloorMaterial == Enum.Material.Air then
		return self:_reject(state, abilityId, "Airborne")
	end

	-- Commit before resolving. The cooldown and the state lock are written
	-- first so that a resolver which errors — or a target that despawns
	-- mid-query — still leaves the caster in a consistent state instead of one
	-- that can be re-entered on the very next frame.
	state.cooldowns[abilityId] = now + ability.Cooldown
	self._players:SetState(state, if ability.Kind == "Mobility" then "Dashing" else "Committed", ability.Commit)

	local ok, resolved = pcall(RESOLVERS[ability.Kind], self, state, ability, direction)
	if not ok then
		warn(`[Arcline/Combat] {abilityId} resolver failed for {player.Name}: {resolved}`)
	end

	local hits = if ok then resolved :: number else 0
	self:_notify(player, abilityId, true, hits, "Ok")
	return true, "Ok"
end

-- Tools are the demo's zero-client-code front-end: Tool.Activated already
-- replicates to the server, so the sample stays a single server script and the
-- input still lands in exactly the same Execute() a remote request would.
function CombatService:_giveTools(player: Player)
	-- WaitForChild rather than FindFirstChild: the Backpack is destroyed
	-- and rebuilt on every respawn, and this runs on a signal thread that
	-- can be racing that rebuild. The timeout is what keeps a player who
	-- left mid-spawn from parking this thread forever.
	local backpack = player:WaitForChild("Backpack", 5)
	local state = self._players:Get(player)
	if not (backpack and state and state.characterBin) then return end

	for _, abilityId in ABILITY_ORDER do
		if not state.loadout[abilityId] then continue end
		-- A CharacterReady from a previous life can still be in flight after
		-- a fast respawn, so an existing name is skipped rather than
		-- stacking a second copy of the hotbar into the new Backpack.
		if backpack:FindFirstChild(abilityId) then continue end

		local tool = Instance.new("Tool")
		tool.Name = abilityId
		-- No Handle, so the demo needs no meshes and no uploaded assets at all.
		tool.RequiresHandle = false
		tool.CanBeDropped = false

		tool.Activated:Connect(function()
			-- The character's CFrame is replicated by the owning client, so it
			-- is input, not truth. It still goes through the same sanitizer, and
			-- the origin used by the query is read on the server at execution
			-- time rather than travelling with the request.
			local current = self._players:Get(player)
			local root = current and current.root
			if root then self:Execute(player, abilityId, root.CFrame.LookVector) end
		end)

		tool.Parent = backpack
		state.characterBin:Add(tool)
	end
end

function CombatService:Start()
	local net = ensureChild(ReplicatedStorage, "Folder", "ArclineNet")
	local request = ensureChild(net, "RemoteEvent", "AbilityRequest") :: RemoteEvent
	local loadout = ensureChild(net, "RemoteFunction", "QueryLoadout") :: RemoteFunction
	self._feedback = ensureChild(net, "RemoteEvent", "CombatFeedback") :: RemoteEvent

	request.OnServerEvent:Connect(function(player: Player, abilityId: any, direction: any)
		-- Every argument here is attacker-controlled by definition: arity, types
		-- and values. Execute() is written to assume exactly that, so this
		-- handler stays a pass-through instead of growing its own partial copy
		-- of the validation rules.
		self:Execute(player, abilityId, direction)
	end)

	loadout.OnServerInvoke = function(caller: any)
		-- A RemoteFunction is used here and nowhere else: the reply is small and
		-- fixed-shape, and a client genuinely needs the round trip to draw its
		-- HUD. The server never invokes the client — a hung client would park
		-- this thread indefinitely. It is rate limited like any other request.
		local player = caller :: Player
		local state = self._players:Get(player)
		if not state or not self._players:ConsumeToken(state) then return nil end

		local now = os.clock()
		local reply: { [string]: number } = {}
		for abilityId in state.loadout do
			reply[abilityId] = math.max(0, (state.cooldowns[abilityId] or 0) - now)
		end
		return reply
	end

	self._players.CharacterReady:Connect(function(player: Player)
		self:_giveTools(player)
	end)

	-- Movement commitment is a listener rather than a branch inside the ability
	-- code: the attack decides how long you are locked, and anything that cares
	-- about being locked subscribes. Adding a stamina drain or a HUD flash later
	-- is one more listener, not another edit inside Execute().
	self._players.StateChanged:Connect(function(player: Player, current: string)
		local state = self._players:Get(player)
		local humanoid = state and state.humanoid
		if humanoid then
			humanoid.WalkSpeed = if current == "Committed" then CONFIG.CommittedWalkSpeed else CONFIG.BaseWalkSpeed
		end
	end)
end

Framework.Register(CombatService)

--== TELEMETRY SERVICE ================================================

local TelemetryService = {
	Name = "Telemetry",
	_players = nil :: any,
	_combat = nil :: any,
}

function TelemetryService:Init()
	self._players = Framework.Get("PlayerState")
	self._combat = Framework.Get("Combat")
end

function TelemetryService:Start()
	self._combat.DamageDealt:Connect(function(player: Player, humanoid: Humanoid, damage: number)
		local state = self._players:Get(player)
		if not state then return end

		-- The running total is accumulated as a float and only rounded for
		-- display: rounding each hit before adding it would let fractional
		-- falloff damage drift the score away from what was actually dealt.
		state.damageDealt += damage
		if state.damageValue then state.damageValue.Value = math.floor(state.damageDealt) end

		if humanoid.Health <= 0 then
			local victim = humanoid.Parent
			print(`[Arcline] {player.Name} eliminated {victim and victim.Name or "?"}`)
		end
	end)

	self._combat.RequestRejected:Connect(function(player: Player, abilityId: string, reason: string)
		-- Rejections are the signal worth watching in a live server, so they are
		-- logged with their reason and a running count instead of dropped
		-- silently. In production this is where an analytics event or an
		-- auto-kick threshold would sit.
		local state = self._players:Get(player)
		warn(`[Arcline/Combat] rejected {abilityId} from {player.Name}: {reason} (total {state and state.rejected or 0})`)
	end)
end

Framework.Register(TelemetryService)

--== BOOTSTRAP ========================================================

Framework.Ignite()
print(`[Arcline] combat online — abilities: {table.concat(ABILITY_ORDER, ", ")}`)

