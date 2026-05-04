# Obito
[![Watch the video](https://img.youtube.com/vi/0zYTbdmuqEA/0.jpg)](https://youtu.be/0zYTbdmuqEA)
A lightweight modular framework for Roblox, inspired by Knit and Current.

Obito handles the boring parts of setting up a game's codebase for you: it
loads your modules, fires lifecycle hooks in the right order, and auto-builds
RemoteEvents/RemoteFunctions from your services so you don't have to.

## INSTALLATION

There's no Wally support yet. You'll have to do it manually for now.

- Step 1: Grab the `Framework.luau` file from this repo.
- Step 2: Put it inside `ReplicatedStorage` as a ModuleScript named `Obito`.

The hierarchy should look like this:

```
ReplicatedStorage
└── Obito             <- the module
```

That's it.

## SET-UP

### SERVER-SIDE

Put a regular `Script` inside `ServerScriptService`. Inside it, require the
module:

```lua
local Obito = require(game:GetService("ReplicatedStorage").Obito)
```

Then point Obito at the folder where your services live:

```lua
Obito.AddServices(path.to.your.services)
```

And finally, start it:

```lua
Obito.Start()
```

You're good. Obito will load every ModuleScript inside the folder you passed,
register them as services, run their `ObitoInit` functions, and then their
`ObitoStart` functions.

### CLIENT-SIDE

Same idea but on the client. Put a `LocalScript` inside `StarterPlayerScripts`:

```lua
local Obito = require(game:GetService("ReplicatedStorage").Obito)

Obito.AddControllers(path.to.your.controllers)

Obito.Start()
```

## IMPORTANT NOTES ABOUT LOADING

There are two ways to load modules. They behave differently when you have
nested folders, so pick the one that fits your project layout.

```
The function:
Obito.AddServices(Directory) // Obito.AddControllers(Directory)

Will load modules like this:

Directory
├─ Module 1        [LOADED]
├─ Module 2        [LOADED]
├─ Module 3        [LOADED]
└─ Module 4        [LOADED]

But if you nest them, the inner ones are skipped:

Directory
├─ Module 1        [LOADED]
├─ Module 2        [LOADED]
│  └─ Module 3     [SKIPPED]
└─ Module 4        [LOADED]
```

```
The function:
Obito.AddServicesDeep(Directory) // Obito.AddControllersDeep(Directory)

Loads everything, including nested modules:

Directory
├─ Module 1        [LOADED]
├─ Module 2        [LOADED]
│  └─ Module 3     [LOADED]
└─ Module 4        [LOADED]
```

Use `AddServicesDeep` if you like grouping modules into subfolders. Use the
regular one if you keep everything flat.

## PRIORITIZING START

Sometimes you want a specific service to start before the others. For example,
your `DataService` should probably be ready before your `ShopService` tries to
read player data. You can force the order like this:

```lua
Obito.PrioritizeStart({
    [1] = "DataService",
    [2] = "CurrencyService",
})
```

The services in the list will start in the given order, and everything else
starts after. The order only applies to `ObitoStart`, not `ObitoInit`. Init is
always run on every module before any Start runs.

### IMPORTANT NOTE ABOUT PRIORITIZING

Use the service's `Name` field, not the ModuleScript's name. They're usually
the same but they don't have to be.

## SERVICES

Services are server-side modules. They live in a folder the server can reach,
usually somewhere inside `ServerScriptService` or `ServerStorage`.

```lua
--// CREATING A SERVICE

local Obito = require(path.to.Obito)

local MyService = Obito.CreateService({
    Name = "MyService"
})

return MyService
```

### ADDING THE START FUNCTION

This runs once Obito has started every service. Put your main logic here.

```lua
function MyService:ObitoStart()
    print("MyService started!")
end
```

### ADDING THE INIT FUNCTION

This runs before any service starts. Use it for setup that other services
might depend on (creating folders, hooking events, etc).

```lua
function MyService:ObitoInit()
    print("MyService initialized!")
end
```

Init runs synchronously across all services. By the time any `ObitoStart` runs,
every service has already finished its `ObitoInit`. So it's safe to reference
other services from inside Start.

### ACCESSING METADATA

You can stick any data you want directly on the service table. The `self`
keyword gives you access to it from any method.

```lua
local MyService = Obito.CreateService({
    Name = "MyService",
    Coins = 0
})

function MyService:ObitoStart()
    print(self.Coins) --> 0
end
```

You can also set fields inside a function and read them later:

```lua
function MyService:ObitoStart()
    self.Coins = 100
    self:CheckCoins()
end

function MyService:CheckCoins()
    return self.Coins
end
```

### EXPOSING METHODS TO THE CLIENT

If you want a method to be callable from the client, put it inside the
`Client` table. Obito will turn it into a RemoteFunction automatically.

```lua
local MyService = Obito.CreateService({
    Name = "MyService",
    Client = {}
})

function MyService.Client:GetCoins(player)
    -- player is passed in by Obito, you don't have to ask for it on the client
    return MyService:GetCoinsForPlayer(player)
end
```

The first argument is always the calling player. After that, anything you pass
from the client comes through.

### REMOTE SIGNALS

If you want to push data from the server to the client (instead of the client
asking for it), use `Obito.RemoteSignal()`:

```lua
local MyService = Obito.CreateService({
    Name = "MyService",
    Client = {
        CoinsChanged = Obito.RemoteSignal()
    }
})

function MyService:GiveCoins(player, amount)
    -- ... add coins ...
    self.Client.CoinsChanged:Fire(player, amount)
end
```

You can also fire to everyone with `:FireAll(...)`, or to everyone except one
player with `:FireExcept(player, ...)`.

### GETTING ANOTHER SERVICE

From inside a service, you can pull a reference to another one:

```lua
function MyService:ObitoStart()
    local DataService = Obito.GetService("DataService")
    DataService:DoSomething()
end
```

This only works after `Obito.Start()` has been called. If you call it during
`ObitoInit`, the other service might not be registered yet, so prefer doing
cross-service calls inside `ObitoStart`.

## CONTROLLERS

Controllers are the client-side equivalent of services. Same shape, same
lifecycle, just on the client.

```lua
--// CREATING A CONTROLLER

local Obito = require(path.to.Obito)

local MyController = Obito.CreateController({
    Name = "MyController"
})

return MyController
```

There's also a shortcut for the local player on the client:

```lua
local me = Obito.Player -- always the LocalPlayer, never nil on client
```

### ADDING THE START FUNCTION

```lua
function MyController:ObitoStart()
    print("MyController started!")
end
```

### ADDING THE INIT FUNCTION

```lua
function MyController:ObitoInit()
    print("MyController initialized!")
end
```

### ACCESSING METADATA

Same as services:

```lua
local MyController = Obito.CreateController({
    Name = "MyController",
    Score = 0
})

function MyController:ObitoStart()
    print(self.Score) --> 0
end
```

### TALKING TO THE SERVER

To call a server-side method from a controller, grab a proxy of the service
through `Obito.GetServerService`:

```lua
function MyController:ObitoStart()
    local MyService = Obito.GetServerService("MyService")

    -- Calls the method declared on MyService.Client.GetCoins
    local coins = MyService:GetCoins()
    print("My coins:", coins)

    -- If the service has a RemoteSignal, you can listen to it like a normal
    -- Obito signal
    MyService.CoinsChanged:Connect(function(amount)
        print("got", amount, "coins")
    end)
end
```

You don't have to add the `player` argument when calling from the client.
Obito wires it up on the server side for you.

## SIGNALS

Obito ships with its own Signal class. It's basically the same idea as
BindableEvent but faster (no argument serialization) and you can pass tables
or instances by reference.

```lua
local Signal = Obito.Signal

local mySignal = Signal.new()

local conn = mySignal:Connect(function(name)
    print("hello", name)
end)

mySignal:Fire("world") --> hello world

conn:Disconnect()
mySignal:Destroy() -- when you're done with the signal entirely
```

You can also use `:Once(fn)` if you only want to listen for the first fire,
or `:Wait()` to yield until the next fire.

## PROMISES

`Obito.Start()` returns a Promise so you can chain off of it. It's a tiny
implementation, not the full A+ spec, but it covers the basics:

```lua
Obito.Start():andThen(function()
    print("everything is up")
end):catch(function(err)
    warn("startup failed:", err)
end)
```

If you'd rather wait synchronously, use `:await()`:

```lua
local ok, err = Obito.Start():await()
if not ok then
    warn(err)
end
```

You can also create your own promises with `Obito.Promise.new(executor)`.

## UTILITIES

A few small helpers that come bundled in. Nothing fancy but they save you
from rewriting them in every project.

### Throttle

Wraps a function so it can only run once per X seconds. Anything in between
is dropped.

```lua
local onClick = Obito.Throttle(function()
    print("clicked")
end, 1) -- max once per second
```

### Debounce

Wraps a function so it only runs after X seconds of inactivity. Each new call
resets the timer. Useful for search bars and stuff.

```lua
local onTyped = Obito.Debounce(function(text)
    print("searching for", text)
end, 0.3)
```

### DeepClone

Recursively clones a table. Handles cycles, so you can't accidentally make it
loop forever.

```lua
local copy = Obito.DeepClone(myTable)
```

### Merge

Shallow merge of one table into another. Like `Object.assign` in JS.

```lua
Obito.Merge(target, source)
```

## API REFERENCE

A quick cheat sheet of everything Obito exposes.

### Server

- `Obito.CreateService(definition)` -> Service
- `Obito.GetService(name)` -> Service
- `Obito.GetServices()` -> table of all services
- `Obito.AddServices(folder)`
- `Obito.AddServicesDeep(folder)`
- `Obito.RemoteSignal()` -> RemoteSignal

### Client

- `Obito.CreateController(definition)` -> Controller
- `Obito.GetController(name)` -> Controller
- `Obito.GetServerService(name)` -> proxy of a server service
- `Obito.AddControllers(folder)`
- `Obito.AddControllersDeep(folder)`
- `Obito.Player` -> LocalPlayer

### Both sides

- `Obito.Start()` -> Promise
- `Obito.IsStarted()` -> boolean
- `Obito.OnStart(callback)` -> runs callback once Obito finishes starting
- `Obito.PrioritizeStart(orderedNames)`
- `Obito.Signal` -> Signal class
- `Obito.Promise` -> Promise class
- `Obito.Throttle(fn, seconds)` -> wrapped fn
- `Obito.Debounce(fn, seconds)` -> wrapped fn
- `Obito.DeepClone(t)` -> table
- `Obito.Merge(target, source)` -> table

## NOTES

- Don't call `CreateService` or `CreateController` after `Start()`. Obito
  asserts against it because the lifecycle hooks have already run.
- `ObitoInit` is synchronous. Don't yield in it (no `wait`, no `:GetAsync`,
  etc) or you'll stall the rest of the boot. Save those calls for `ObitoStart`.
- If a module errors during loading, Obito will warn but keep going. The other
  modules still get a chance to start. Check the output if something seems off.
