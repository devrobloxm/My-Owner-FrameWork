--[[

	Obito - lightweight modular framework for Roblox (server + client)

	a Knit-inspired framework, built from scratch.. handles loading and
	bootstrapping Services on the server and Controllers on the client,
	plus an internal Signal class, a tiny Promise impl for :Start(), and
	auto-built RemoteEvents/RemoteFunctions through a Net layer.

	core stuff ; CreateService, CreateController, AddServices, AddControllers,
	AddServicesDeep, AddControllersDeep, PrioritizeStart, Start, OnStart,
	Signal, Promise, Net.

	-Discord: yourdiscord / Roblox: yourrobloxname : 12/05/2025

	[FOR HD LUAU SCRIPTER APPLICATION, WHICH EXPLAINS LOTS OF COMMENTS.]

]]--

-- Services
--  grabbing all the services we need up here so we dont call game:GetService
--  in the middle of hot code paths. it's like 1 micro-optimization but also
--  just way cleaner to read

local RunService       = game:GetService("RunService")        -- need this for IsServer/IsClient detection
local Players          = game:GetService("Players")           -- only used on client to grab LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- where we put the auto-generated remotes folder

-- Constants

local IS_SERVER = RunService:IsServer()           -- cache it.. we check this a lot
local IS_CLIENT = RunService:IsClient()           -- same as above just opposite ofc
local STARTED_TIMEOUT = 10                        -- seconds before client gives up waiting for server start

-- Type defs
--  these aren't enforced at runtime really but they make autocomplete go brrr in Studio
--  (and anyone reading the code knows the shape of stuff right away)

export type ServiceDef = {
	Name: string,                                 -- unique name, used by other services to reference this one
	Client: { [string]: any }?,                   -- optional table holding client-exposed methods/signals
	[string]: any,                                -- everything else (custom data, methods)
}

export type ControllerDef = {
	Name: string,                                 -- unique name, like services but for client
	[string]: any,                                -- custom methods/data
}

export type Service = ServiceDef                  -- alias.. once registered it's basically the same shape
export type Controller = ControllerDef            -- ditto for controllers

export type Connection = {
	Disconnect: (self: Connection) -> (),         -- the only method on a connection.. drops it from the signal
	Connected: boolean,                           -- false after :Disconnect was called
}

export type Signal = {
	Connect: (self: Signal, fn: (...any) -> ()) -> Connection, -- normal listener
	Once: (self: Signal, fn: (...any) -> ()) -> Connection,    -- auto-disconnects after first fire
	Wait: (self: Signal) -> ...any,                            -- yields until next fire
	Fire: (self: Signal, ...any) -> (),                        -- broadcast to listeners
	Destroy: (self: Signal) -> (),                             -- kill all listeners + mark as dead
}

-- Module
--  the main table, kinda like Knit. all public API is hung off this

local Obito = {}
Obito.Player = if IS_CLIENT then Players.LocalPlayer else nil  -- shortcut for client.. nil on server obv

-- Internal storage
--  these are where loaded services/controllers live + flags about lifecycle.
--  we keep them at module-level (closure) so theyre fully private from the outside

local services: { [string]: Service } = {}        -- map of name -> service. on server only
local controllers: { [string]: Controller } = {}  -- same shape but for client
local startedFlag = false                          -- becomes true once :Start has run successfully
local startingFlag = false                         -- guards :Start so u cant call it twice
local priorityList: { string } = {}                -- ordered names, set by PrioritizeStart
local pendingFolders: { Instance } = {}            -- folders waiting to be loaded inside :Start
local pendingFoldersDeep: { Instance } = {}        -- same idea but recursive load (children too)
local onStartCallbacks: { (any?) -> () } = {}      -- queued :OnStart() callbacks if user calls before Start

-- Signal
--  homemade signal class. scripted this instead of using BindableEvent
--  because BindableEvent serializes args (loses references, tables get
--  copied) and it costs more for high-frequency events. plain lua signal
--  is faster + you keep your refs intact

local Signal = {}                                  -- class table
Signal.__index = Signal                            -- normal metatable setup

--  helper that kills + reuses connection node objects.. tiny pool to avoid
--  spamming gc when you connect/disconnect a lot (combat games etc)
local connectionPool: { any } = {}

local function newConnection(signal: any, fn: (...any) -> ()): Connection
	local conn
	if #connectionPool > 0 then
		--  reuse an old one if avail.. saves an Instance.new equivalent allocation
		conn = table.remove(connectionPool)
		conn._signal = signal
		conn._fn = fn
		conn.Connected = true
	else
		--  fresh node
		conn = {
			_signal = signal,
			_fn = fn,
			_next = nil,
			Connected = true,
		}
	end

	--  the disconnect method removes us from the linked list
	function conn:Disconnect()
		if not self.Connected then
			return                                -- already disconnected, no-op
		end
		self.Connected = false

		local sig = self._signal
		if sig then
			--  unlink from singly-linked list. head case + middle case
			if sig._head == self then
				sig._head = self._next
			else
				local node = sig._head
				while node and node._next ~= self do
					node = node._next            -- walk forward
				end
				if node then
					node._next = self._next      -- splice us out
				end
			end
		end

		self._signal = nil
		self._fn = nil
		self._next = nil

		--  send back to the pool for reuse later
		if #connectionPool < 64 then              -- cap pool so it doesnt grow forever
			table.insert(connectionPool, self)
		end
	end

	return conn :: any
end

function Signal.new(): Signal
	local self = setmetatable({}, Signal)
	self._head = nil                              -- linked list head, nil = no listeners
	self._destroyed = false                       -- once destroyed, all ops become no-ops
	return (self :: any) :: Signal
end

function Signal:Connect(fn: (...any) -> ()): Connection
	assert(typeof(fn) == "function", "Signal:Connect expects a function")
	if self._destroyed then
		--  return a dummy connection thats already disconnected
		--  prevents nil errors from old code holding a destroyed signal
		return { Disconnect = function() end, Connected = false } :: any
	end

	local conn = newConnection(self, fn)
	conn._next = self._head                       -- prepend to head (cheap insert)
	self._head = conn
	return conn :: Connection
end

function Signal:Once(fn: (...any) -> ()): Connection
	--  this one auto-disconnects after the first fire. handy for one-shot stuff
	local conn: Connection
	conn = self:Connect(function(...)
		if conn.Connected then
			conn:Disconnect()
		end
		fn(...)                                   -- still call user's fn after disconnecting
	end)
	return conn
end

function Signal:Wait(): ...any
	--  yields current thread until next Fire. uses a coroutine-style trick
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		if conn.Connected then
			conn:Disconnect()
		end
		--  resume the yielded thread w/ the fired args
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Fire(...: any)
	if self._destroyed then return end

	--  walk linked list and call each listener in its own thread (task.spawn)
	--  so one bad listener cant block the others. classic robust signal pattern
	local node = self._head
	while node do
		local nxt = node._next                    -- snapshot next first.. listener might disconnect itself
		if node.Connected and node._fn then
			task.spawn(node._fn, ...)
		end
		node = nxt
	end
end

function Signal:Destroy()
	self._destroyed = true
	--  walk + disconnect everything so threads waiting on :Wait dont leak
	local node = self._head
	while node do
		local nxt = node._next
		node.Connected = false
		node._signal = nil
		node._fn = nil
		node._next = nil
		node = nxt
	end
	self._head = nil
end

Obito.Signal = Signal                             -- expose as Obito.Signal.new()

-- Promise
--  super tiny promise impl. not full A+ compliant.. just enough for
--  Obito.Start() to chain :andThen / :catch / :await without pulling
--  in the whole roblox-lua-promise lib (~1k lines). this is like 80 lines

local Promise = {}
Promise.__index = Promise

--  3 states: pending, resolved (success), rejected (error). pretty standard
local STATE_PENDING  = "pending"
local STATE_RESOLVED = "resolved"
local STATE_REJECTED = "rejected"

function Promise.new(executor: (resolve: (any?) -> (), reject: (any?) -> ()) -> ()): any
	local self = setmetatable({}, Promise)
	self._state = STATE_PENDING
	self._value = nil
	self._thens = {}                              -- queued success callbacks
	self._catches = {}                            -- queued error callbacks
	self._waiters = {}                            -- threads yielded on :await()

	--  helper that flushes appropriate queue once we settle
	local function settle(state: string, value: any?)
		if self._state ~= STATE_PENDING then
			return                                -- already settled.. ignore double calls (per spec)
		end
		self._state = state
		self._value = value

		local list = if state == STATE_RESOLVED then self._thens else self._catches
		for _, cb in ipairs(list) do
			task.spawn(cb, value)                 -- spawn so a slow callback doesnt block others
		end

		--  resume anyone yielded on :await()
		for _, thr in ipairs(self._waiters) do
			task.spawn(thr, state == STATE_RESOLVED, value)
		end

		self._thens = {}                          -- clear queues, dont need em anymore
		self._catches = {}
		self._waiters = {}
	end

	--  resolve/reject given to executor are just sugar around settle
	local function resolve(v: any?) settle(STATE_RESOLVED, v) end
	local function reject(v: any?) settle(STATE_REJECTED, v) end

	--  run the executor in a pcall so thrown errors auto-reject (consistent w/ JS promises)
	local ok, err = pcall(executor, resolve, reject)
	if not ok then
		reject(err)
	end

	return self
end

function Promise:andThen(onResolved: (any?) -> ()): any
	if self._state == STATE_RESOLVED then
		task.spawn(onResolved, self._value)       -- already done.. fire immediately on next frame
	elseif self._state == STATE_PENDING then
		table.insert(self._thens, onResolved)     -- queue it
	end
	--  rejected -> just skip, like JS .then ignores when rejected
	return self
end

function Promise:catch(onRejected: (any?) -> ()): any
	if self._state == STATE_REJECTED then
		task.spawn(onRejected, self._value)
	elseif self._state == STATE_PENDING then
		table.insert(self._catches, onRejected)
	end
	return self
end

function Promise:await(): (boolean, any?)
	if self._state == STATE_RESOLVED then
		return true, self._value                  -- already resolved.. just return
	elseif self._state == STATE_REJECTED then
		return false, self._value
	end
	--  yield current thread, settle() will resume it
	table.insert(self._waiters, coroutine.running())
	return coroutine.yield()
end

Obito.Promise = Promise

-- Net
--  tiny networking layer. when a service has a .Client table, every
--  function in it gets auto-wrapped into a RemoteEvent / RemoteFunction.
--  events fire one-way, functions return a value (use sparingly, blocking)

local Net = {}
local netRoot: Folder? = nil                      -- the parent folder for all generated remotes

--  lazily make the folder so we dont pollute ReplicatedStorage on require
local function ensureNetRoot(): Folder
	if netRoot and netRoot.Parent then
		return netRoot
	end

	if IS_SERVER then
		--  server creates the folder, client just waits for it
		local existing = ReplicatedStorage:FindFirstChild("ObitoNet")
		if existing then
			netRoot = existing :: Folder
		else
			local f = Instance.new("Folder")
			f.Name = "ObitoNet"
			f.Parent = ReplicatedStorage
			netRoot = f
		end
	else
		netRoot = ReplicatedStorage:WaitForChild("ObitoNet", STARTED_TIMEOUT) :: Folder
	end
	return netRoot :: Folder
end

--  per-service folder under ObitoNet/, keeps remotes namespaced
local function getServiceFolder(serviceName: string): Folder
	local root = ensureNetRoot()
	local existing = root:FindFirstChild(serviceName)
	if existing then
		return existing :: Folder
	end

	if IS_SERVER then
		local f = Instance.new("Folder")
		f.Name = serviceName
		f.Parent = root
		return f
	else
		--  shouldnt really hit here on client.. WaitForChild as fallback
		return root:WaitForChild(serviceName, STARTED_TIMEOUT) :: Folder
	end
end

--  build remotes for a service.Client table. called during :Start on server
function Net._buildForService(service: Service)
	if not IS_SERVER then return end              -- server-only, clients just consume
	if not service.Client then return end         -- no client api, skip

	local folder = getServiceFolder(service.Name)

	--  for each method/signal in service.Client, decide what kind of remote we need
	for key, value in pairs(service.Client) do
		if typeof(value) == "function" then
			--  RemoteFunction so client can :InvokeServer and get a return value
			local rf = Instance.new("RemoteFunction")
			rf.Name = key
			rf.Parent = folder

			--  hook OnServerInvoke to pass-through to the original method
			--  we pass `service.Client` as self so user code looks like normal OOP
			rf.OnServerInvoke = function(player: Player, ...)
				--  pcall so a bad client cant crash the whole service w/ weird args
				local ok, result = pcall(value, service.Client, player, ...)
				if not ok then
					warn(("[Obito/Net] %s.%s errored: %s"):format(service.Name, key, tostring(result)))
					return nil                    -- swallow the error, return nil to client
				end
				return result
			end
		elseif typeof(value) == "table" and value._isObitoSignal then
			--  custom marker we stamp on signals via Obito.RemoteSignal()
			--  bind the existing RemoteEvent under a name. covered below
			value:_attach(folder, key)
		end
	end
end

--  factory for a server->client signal. its like a Signal but it goes thru a RemoteEvent
function Obito.RemoteSignal(): any
	local self = {}
	self._isObitoSignal = true                    -- marker for Net._buildForService to find us
	self._remote = nil :: RemoteEvent?            -- assigned during :_attach
	self._listeners = {}                          -- for server-side OnServerEvent if needed (client recv only here)

	function self:_attach(parent: Folder, name: string)
		--  called by Net during build. creates the actual remote event instance
		local r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = parent
		self._remote = r
	end

	function self:Fire(player: Player, ...)
		--  send to one specific player.. typical case
		if self._remote then
			self._remote:FireClient(player, ...)
		end
	end

	function self:FireAll(...)
		--  broadcast to everyone. use sparingly cuz bandwidth
		if self._remote then
			self._remote:FireAllClients(...)
		end
	end

	function self:FireExcept(excluded: Player, ...)
		--  fire to everyone EXCEPT one player. handy for "tell others i did X"
		if not self._remote then return end
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= excluded then
				self._remote:FireClient(plr, ...)
			end
		end
	end

	return self
end

Obito.Net = Net                                   -- mostly internal but exposed in case someone needs it

-- Service API
--  all the service-related public functions. only valid on server.. clients
--  using these will just get an assert error which i think is fair

function Obito.CreateService(definition: ServiceDef): Service
	assert(IS_SERVER, "[Obito] CreateService can only be called from the server")
	assert(typeof(definition) == "table", "[Obito] CreateService expects a table")
	assert(typeof(definition.Name) == "string" and #definition.Name > 0, "[Obito] Service.Name must be a non-empty string")
	assert(not startedFlag, "[Obito] Cannot create services after Start()")
	assert(not services[definition.Name], ("[Obito] Service '%s' already exists"):format(definition.Name))

	--  ensure a Client table even if the dev didnt supply one. simplifies later code
	if definition.Client == nil then
		definition.Client = {}
	end

	services[definition.Name] = definition
	return definition
end

function Obito.GetService(name: string): Service
	assert(IS_SERVER, "[Obito] GetService is server-side. Use GetController on client.")
	assert(startedFlag or startingFlag, "[Obito] GetService can only be called after :Start()")
	local svc = services[name]
	assert(svc, ("[Obito] Service '%s' not found"):format(name))
	return svc
end

function Obito.GetServices(): { [string]: Service }
	--  returns a copy so callers cant mutate our internal table directly
	local copy = {}
	for k, v in pairs(services) do
		copy[k] = v
	end
	return copy
end

-- Controller API

function Obito.CreateController(definition: ControllerDef): Controller
	assert(IS_CLIENT, "[Obito] CreateController can only be called from the client")
	assert(typeof(definition) == "table", "[Obito] CreateController expects a table")
	assert(typeof(definition.Name) == "string" and #definition.Name > 0, "[Obito] Controller.Name must be a non-empty string")
	assert(not startedFlag, "[Obito] Cannot create controllers after Start()")
	assert(not controllers[definition.Name], ("[Obito] Controller '%s' already exists"):format(definition.Name))

	controllers[definition.Name] = definition
	return definition
end

function Obito.GetController(name: string): Controller
	assert(IS_CLIENT, "[Obito] GetController is client-side")
	assert(startedFlag or startingFlag, "[Obito] GetController can only be called after :Start()")
	local ctrl = controllers[name]
	assert(ctrl, ("[Obito] Controller '%s' not found"):format(name))
	return ctrl
end

--  on client, Obito.GetService doesnt return a real service.. it returns a
--  proxy that auto-routes calls to RemoteFunctions/RemoteEvents under
--  ObitoNet/<service name>/. this is the "client side service proxy" pattern
function Obito.GetServerService(name: string): { [string]: any }
	assert(IS_CLIENT, "[Obito] GetServerService is client-side only")
	local netFolder = ensureNetRoot()
	local svcFolder = netFolder:WaitForChild(name, STARTED_TIMEOUT)
	assert(svcFolder, ("[Obito] Server service '%s' not found in net layer"):format(name))

	--  build a proxy table whose __index resolves to a wrapper around
	--  RemoteFunction:InvokeServer or a Signal-like for RemoteEvents
	local proxy = {}
	for _, child in ipairs(svcFolder:GetChildren()) do
		if child:IsA("RemoteFunction") then
			--  RemoteFunction -> turn into a method on the proxy
			proxy[child.Name] = function(_self, ...)
				return child:InvokeServer(...)    -- fire & wait for return
			end
		elseif child:IsA("RemoteEvent") then
			--  RemoteEvent -> wrap in a local Signal, hook OnClientEvent into Fire
			local sig = Signal.new()
			child.OnClientEvent:Connect(function(...)
				sig:Fire(...)
			end)
			proxy[child.Name] = sig
		end
	end

	return proxy
end

-- Loading / boot
--  these queue folders to be loaded inside :Start. we dont load right away
--  so the user can call AddServices multiple times before starting
--  (ex: 1 folder for gameplay, 1 for ui, etc)

local function isLoadable(inst: Instance): boolean
	--  returns true if this instance can be required as a module
	return inst:IsA("ModuleScript")
end

local function flatLoad(folder: Instance, deep: boolean)
	--  deep = also walk descendants. otherwise just direct children
	local items = if deep then folder:GetDescendants() else folder:GetChildren()
	for _, child in ipairs(items) do
		if isLoadable(child) then
			--  pcall so 1 broken module doesnt crash the whole startup
			local ok, err = pcall(require, child)
			if not ok then
				warn(("[Obito] failed to load %s: %s"):format(child:GetFullName(), tostring(err)))
			end
			--  the modulescript should be calling CreateService/CreateController
			--  internally. we dont need to do anything w the return value
		end
	end
end

function Obito.AddServices(folder: Instance): typeof(Obito)
	assert(IS_SERVER, "[Obito] AddServices is server-only")
	assert(typeof(folder) == "Instance", "[Obito] AddServices expects an Instance")
	table.insert(pendingFolders, folder)
	return Obito                                  -- return self for chaining if u want
end

function Obito.AddServicesDeep(folder: Instance): typeof(Obito)
	assert(IS_SERVER, "[Obito] AddServicesDeep is server-only")
	assert(typeof(folder) == "Instance", "[Obito] AddServicesDeep expects an Instance")
	table.insert(pendingFoldersDeep, folder)
	return Obito
end

function Obito.AddControllers(folder: Instance): typeof(Obito)
	assert(IS_CLIENT, "[Obito] AddControllers is client-only")
	assert(typeof(folder) == "Instance", "[Obito] AddControllers expects an Instance")
	table.insert(pendingFolders, folder)
	return Obito
end

function Obito.AddControllersDeep(folder: Instance): typeof(Obito)
	assert(IS_CLIENT, "[Obito] AddControllersDeep is client-only")
	assert(typeof(folder) == "Instance", "[Obito] AddControllersDeep expects an Instance")
	table.insert(pendingFoldersDeep, folder)
	return Obito
end

function Obito.PrioritizeStart(order: { string }): typeof(Obito)
	--  the names in `order` will have :ObitoStart called on them first, in order.
	--  any modules not in the list still get started, just after the priority ones
	assert(typeof(order) == "table", "[Obito] PrioritizeStart expects a table")
	priorityList = table.clone(order)             -- copy so user can mutate their table later w/o affecting us
	return Obito
end

function Obito.OnStart(callback: (any?) -> ()): typeof(Obito)
	--  if Obito already started, fire immediately. otherwise queue it
	if startedFlag then
		task.spawn(callback)                      -- fire on next frame so callsite can return first
	else
		table.insert(onStartCallbacks, callback)
	end
	return Obito
end

-- Start
--  the big one. loads everything, calls ObitoInit on all modules,
--  then ObitoStart, then sets the started flag, then fires OnStart cbs.
--  returns a Promise so u can :catch(warn) or :await() it

local function callObitoInit(modules: { [string]: any })
	--  ObitoInit runs synchronously for ALL modules before ANY ObitoStart fires.
	--  this lets services reference each other safely during startup
	--  (similar to Knit's KnitInit)
	for name, mod in pairs(modules) do
		if typeof(mod.ObitoInit) == "function" then
			local ok, err = pcall(mod.ObitoInit, mod)
			if not ok then
				warn(("[Obito] %s:ObitoInit errored: %s"):format(name, tostring(err)))
			end
		end
	end
end

local function callObitoStart(modules: { [string]: any })
	--  ObitoStart is fired in its own thread per module so blocking calls
	--  (waits, datastore reads etc) dont stall everything else

	--  first: priority modules in order
	local fired: { [string]: boolean } = {}
	for _, name in ipairs(priorityList) do
		local mod = modules[name]
		if mod and typeof(mod.ObitoStart) == "function" then
			task.spawn(function()
				local ok, err = pcall(mod.ObitoStart, mod)
				if not ok then
					warn(("[Obito] %s:ObitoStart errored: %s"):format(name, tostring(err)))
				end
			end)
			fired[name] = true
		elseif mod then
			fired[name] = true                    -- still mark as "handled" so we dont double-fire below
		end
	end

	--  then: everyone else
	for name, mod in pairs(modules) do
		if not fired[name] and typeof(mod.ObitoStart) == "function" then
			task.spawn(function()
				local ok, err = pcall(mod.ObitoStart, mod)
				if not ok then
					warn(("[Obito] %s:ObitoStart errored: %s"):format(name, tostring(err)))
				end
			end)
		end
	end
end

function Obito.Start(): any
	if startedFlag then
		--  return an already-resolved promise so :andThen still works the same way.
		--  weve all written code that calls Start in two places by accident lol
		return Promise.new(function(resolve)
			resolve(nil)
		end)
	end
	if startingFlag then
		--  someone called Start while a previous Start is still mid-flight (shouldnt
		--  happen but just in case).. reject this one
		return Promise.new(function(_, reject)
			reject("[Obito] Start already in progress")
		end)
	end

	startingFlag = true

	return Promise.new(function(resolve, reject)
		--  use task.spawn so the executor itself returns immediately and the promise
		--  is properly created before we start yielding on requires
		task.spawn(function()
			--  step 1: load all queued folders (this triggers CreateService/CreateController
			--  inside each module, which fills in the services / controllers tables)
			for _, f in ipairs(pendingFolders) do
				flatLoad(f, false)
			end
			for _, f in ipairs(pendingFoldersDeep) do
				flatLoad(f, true)
			end

			--  step 2: figure out which side we are and pick the right modules table
			local modules = if IS_SERVER then services else controllers

			--  step 3: build remotes from service.Client tables (server only)
			if IS_SERVER then
				for _, svc in pairs(services) do
					Net._buildForService(svc)
				end
			end

			--  step 4: ObitoInit on everything (sync, blocking)
			callObitoInit(modules)

			--  step 5: ObitoStart on everything (async, spawned)
			callObitoStart(modules)

			--  step 6: mark started + fire any queued OnStart callbacks
			startedFlag = true
			startingFlag = false
			for _, cb in ipairs(onStartCallbacks) do
				task.spawn(cb)
			end
			onStartCallbacks = {}                 -- clear queue

			resolve(nil)
		end)
	end)
end

function Obito.IsStarted(): boolean
	return startedFlag
end

-- Utilities
--  small grab-bag of helper functions u always end up needing

--  shallow merge.. like Object.assign in JS
function Obito.Merge<T>(target: { [any]: T }, source: { [any]: T }): { [any]: T }
	for k, v in pairs(source) do
		target[k] = v
	end
	return target
end

--  deep clone, handles nested tables. avoids cycles by tracking seen tables in `seen`
function Obito.DeepClone<T>(orig: T, seen: { [any]: any }?): T
	if typeof(orig) ~= "table" then
		return orig                               -- primitive, just return as-is
	end
	seen = seen or {}
	if seen[orig] then
		return seen[orig]                         -- cycle.. return whatever we already cloned for this one
	end

	local copy: any = {}
	seen[orig] = copy                             -- remember now in case theres a cycle inside
	for k, v in pairs(orig :: any) do
		copy[Obito.DeepClone(k, seen)] = Obito.DeepClone(v, seen)
	end
	return (copy :: any) :: T
end

--  bare-bones throttle. returns a wrapped version of `fn` that wont call
--  more than once per `seconds`. useful for spammy events like player input
function Obito.Throttle(fn: (...any) -> (), seconds: number): (...any) -> ()
	local lastCall = 0
	return function(...)
		local now = os.clock()
		if now - lastCall >= seconds then
			lastCall = now
			fn(...)
		end
		--  silently drop calls in between, like rbxutil's Timer:Throttle
	end
end

--  debounce: only fires after `seconds` of no calls. opposite of throttle basically
function Obito.Debounce(fn: (...any) -> (), seconds: number): (...any) -> ()
	local pending: thread? = nil
	return function(...)
		local args = table.pack(...)
		if pending then
			task.cancel(pending)                  -- kill the previous queued call.. user called us again
		end
		pending = task.delay(seconds, function()
			pending = nil
			fn(table.unpack(args, 1, args.n))
		end)
	end
end

return Obito
