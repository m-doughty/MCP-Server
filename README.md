[![Actions Status](https://github.com/m-doughty/MCP-Server/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/MCP-Server/actions)

MCP::Server
===========

A framework for building MCP (Model Context Protocol) servers in Raku. Register tools, resources, and prompts — the framework handles the JSON-RPC 2.0 protocol, message dispatch, and both protocol eras (`2025-11-25` and `2026-07-28`), over stdio or Streamable HTTP.

Synopsis
--------

```raku
use MCP::Server;

my $server = MCP::Server.new(:name<my-tools>, :version<1.0>);

$server.tool: 'greet',
    description => 'Greet someone by name',
    params => {
        name => { type => 'string', description => 'Name to greet', required => True },
    },
    handler => -> :%args { "Hello, {%args<name>}!" };

$server.run;  # Listens on stdin/stdout
```

Use with Claude Code:

```json
{
  "mcpServers": {
    "my-tools": {
      "command": "raku",
      "args": ["-I", "lib", "examples/my-server.raku"]
    }
  }
}
```

Tools
-----

Tools are functions the LLM can call. Define parameters with types and descriptions — the framework generates JSON Schema automatically.

```raku
$server.tool: 'search',
    description => 'Search the web',
    params => {
        query => { type => 'string', description => 'Search query', required => True },
        limit => { type => 'integer', description => 'Max results' },
    },
    handler => -> :%args {
        # Return a string (wrapped as text content)
        "Results for {%args<query>}..."
    };
```

Tool handlers receive `:%args` and return:

  * `Str` — wrapped as `[{type: "text", text: $result}]`

  * `List` — passed through as content items

  * On exception — returned as `isError: true` content

Tool Groups
-----------

Group related tools under a common prefix. Names are joined with `_` (underscore), not `/`:

```raku
$server.tool-group: 'file', -> $g {
    $g.tool: 'read',
        description => 'Read a file',
        params => { path => { type => 'string', required => True } },
        handler => -> :%args { %args<path>.IO.slurp };

    $g.tool: 'list',
        description => 'List a directory',
        params => { path => { type => 'string', required => True } },
        handler => -> :%args { %args<path>.IO.dir.join("\n") };
};
# Registers as: file_read, file_list
```

The separator matters because the MCP spec restricts tool names to `[A-Za-z0-9_-]`, at most 128 characters — a `/` would produce a name no client could call. Registering a tool with an invalid name, or one that collides with a name already registered on the server, dies immediately (with a message naming the offending tool) rather than silently overwriting the earlier registration:

```raku
$server.tool: 'file/read', handler => -> :%args { };
# dies: Invalid tool name 'file/read': MCP tool names must be 1 to 128
# characters of [A-Za-z0-9_-]

$server.tool: 'read', handler => -> :%args { 1 };
$server.tool: 'read', handler => -> :%args { 2 };
# dies: Duplicate tool 'read' on MCP server '...'; register one of the
# providers under a prefix, e.g. $server.plug($kit, :prefix<other>)
```

The same rules apply to prompts (duplicate names) and resources (duplicate URIs).

Toolkits
--------

A toolkit is a self-contained bundle of tools, prompts, and resources that plugs into any `MCP::Server`. Toolkits are how you distribute reusable tool packs as their own zef distributions — see "Writing a tool pack" below — but a toolkit can just as easily live in the same file as the server that uses it.

### The `MCP::Server::Toolkit` role

```raku
use MCP::Server::Toolkit;
role MCP::Server::Toolkit {
    method register($registrar) { ... }             # required
    method default-prefix(--> Str) { Str }           # optional, defaults to none
    method from-config(::?CLASS:U: %config) { ... }  # provided
}
```

  * `register($registrar)` — required. Register everything the toolkit provides by calling `.tool`, `.prompt`, and `.resource` on the supplied registrar; its method signatures match `MCP::Server`'s own.

  * `default-prefix` — optional. The prefix applied when `.plug` is called with no explicit `:prefix`. The default implementation returns an undefined `Str`, meaning "no prefix unless the caller asks for one".

  * `from-config(%config)` — provided by the role, not something you normally override. Builds an instance from a plain (JSON-shaped) hash, validating every key against the class's public attributes: unknown keys and missing required attributes both die, listing the valid or missing keys in the message. A `prefix` key inside `%config` is rejected as reserved — it belongs beside the entry when plugging or in a `:tools` list, not inside the toolkit's own config.

Here is a complete worked example — everything a small toolkit distribution needs:

```raku
use MCP::Server::Toolkit;

unit class MCP::Server::Tool::Weather does MCP::Server::Toolkit;

has Str:D $.units = 'metric';     # optional -- has a default
has Str:D $.api-key is required;  # required -- from-config demands it

method default-prefix(--> Str) { 'weather' }

method register($registrar) {
    $registrar.tool: 'forecast',
        description => 'Get a forecast for a location',
        params => {
            location => { type => 'string', description => 'City name', required => True },
        },
        handler => -> :%args {
            fetch-forecast(%args<location>, :$!units, :$!api-key);
        };

    $registrar.resource: 'weather://stations',
        name        => 'Known stations',
        description => 'Stations this toolkit can report on',
        mime-type   => 'text/plain',
        handler     => -> :%args { known-stations().join("\n") };
}
```

```raku
use MCP::Server;
use MCP::Server::Tool::Weather;

my $server = MCP::Server.new(:name<my-tools>);
$server.plug: MCP::Server::Tool::Weather.new(:api-key<secret>);
# default-prefix 'weather' applies automatically:
# registers weather_forecast and weather://weather/stations
```

### Prefixing rules

`$server.plug($kit, :prefix<...>)` namespaces everything the toolkit registers:

  * Tool and prompt names become `"{prefix}_{name}"`.

  * Resource URIs get the prefix injected as the first path segment. `scheme://path` becomes `scheme://prefix/path`; a bare (no `://`) URI becomes `prefix/path`. Leading slashes on the remainder are stripped so authority-less URIs don't end up with an empty path segment: `file:///etc/hosts` with prefix `docs` becomes `file://docs/etc/hosts`, not `file://docs//etc/hosts`.

Precedence for which prefix applies: an explicit `:prefix` argument to `.plug` beats the toolkit's own `default-prefix`, which beats no prefix at all.

```raku
$server.plug: MCP::Server::Tool::Weather.new(:api-key<x>);
# Uses default-prefix 'weather' -> weather_forecast

$server.plug: MCP::Server::Tool::Weather.new(:api-key<x>), :prefix<wx>;
# Explicit :prefix wins -> wx_forecast

$server.plug: MCP::Server::Tool::TestKit.new;
# TestKit declares no default-prefix -> registers bare: greet
```

Plugging two toolkits (or the same toolkit twice) that would produce the same name dies with a message suggesting a `:prefix`, exactly like the collision case in "Tool Groups" above:

```raku
$server.plug: MCP::Server::Tool::TestKit.new;
$server.plug: MCP::Server::Tool::TestKit.new;
# dies: Duplicate tool 'greet' on MCP server '...'; register one of the
# providers under a prefix, e.g. $server.plug($kit, :prefix<other>)

$server.plug: MCP::Server::Tool::TestKit.new, :prefix<second>;  # fine
```

`:sep` overrides the character joining prefix and name (default `_`). Since MCP tool names only allow `[A-Za-z0-9_-]`, the only other sensible choice is `-`:

```raku
$server.plug: $kit, :prefix<kit>, :sep<->;
# kit-greet instead of kit_greet
```

### mcp classes are toolkits too

Any class declared with the `mcp` DSL (`MCP::Server::DSL`) already does `MCP::Server::Toolkit`, so it can be plugged into a bigger server the same way as a hand-written pack — every public method becomes a tool (with its Pod6 `#|` comment as the description) and every public attribute becomes a read-only tool that reports its value:

```raku
use MCP::Server::DSL;
use MCP::Server;

mcp Calculator {
    #| Add two numbers
    method add(Int :$a!, Int :$b!) { $a + $b }
}

my $host = MCP::Server.new(:name<host>);
$host.plug: Calculator.new, :prefix<calc>;
# Registers calc_add
```

An `mcp` class's own standalone server — built lazily by `.server` and used internally by `.run`, `.tools-for-llm`, `.execute-tool-calls`, and `.handle-request` — is entirely separate from any server it gets plugged into; plugging doesn't consume or replace it, and `.server` is only ever built the first time something needs it. `register`, `server`, `from-config`, and `default-prefix` are the method names the DSL's machinery relies on, so an `mcp` class must not declare its own methods with those names — doing so shadows the framework instead of adding a tool. `from-config` still works on `mcp` classes exactly as it does on any other toolkit, deriving its schema from the class's public attributes; the private `$!server` attribute is never a valid config key.

LLM Tool Bridge
---------------

Tools registered with MCP::Server can be used with any OpenAI-compatible LLM API. Define tools once, use them both as MCP tools (for Claude Code) and as function-calling tools (for LLM API calls).

```raku
use MCP::Server;
use LLM::Chat::Backend::OpenAICommon;
use LLM::Chat::Backend::Settings;
use LLM::Chat::Conversation::Message;
use LLM::Chat::ToolLoop;

# Define tools
my $server = MCP::Server.new(:name<my-tools>);

$server.tool: 'get_weather',
    description => 'Get weather for a location',
    params => { location => { type => 'string', required => True } },
    handler => -> :%args {
        my $proc = run 'curl', '-s', "https://wttr.in/{%args<location>}?format=3", :out;
        $proc.out.slurp(:close).trim;
    };

# Convert to OpenAI format and send to LLM
my @tools = $server.tools-for-llm;
my $backend = LLM::Chat::Backend::OpenAICommon.new(...);
my @messages = (Message.new(:role<user>, :content<What is the weather in London?>),);

my $loop = LLM::Chat::ToolLoop.new(
    backend => $backend,
    tools => @tools,
    execute-tools => -> @calls { $server.execute-tool-calls(@calls) },
);

my $resp = $loop.chat-completion-stream(@messages);
until $resp.is-done { sleep 0.01 }
say $resp.msg if $resp.is-success;
```

`tools-for-llm` converts registered tools to the OpenAI function-calling format, sorted by name so the declarations a prompt carries are stable between runs. `execute-tool-calls` routes the LLM's tool call requests to your registered handlers and returns results ready to send back. Tool results include `role`, `tool_call_id`, `content`, and `is_error`.

Each call's `arguments` may be a hash or the JSON string most APIs actually send; an empty or blank string means "no arguments", which is what models send for a tool that takes none. Anything else that is not a JSON object comes back as a result with `is_error` set, never as an exception.

Resources
---------

Resources expose data the LLM can read.

```raku
$server.resource: 'config://app',
    name => 'App Config',
    description => 'Application configuration',
    mime-type => 'application/json',
    handler => -> :%args { '{"debug": true}' };
```

### Cacheability

`:ttl-ms` and `:cache-scope` tell a 2026-07-28 client how long it may hold on to what a read returned, and whether the answer is the same for everybody. They are optional, and their absence is deliberately pessimistic: a read runs arbitrary handler code whose freshness only its author knows, so a resource that says nothing is reported as `ttlMs: 0` (do not cache) and `cacheScope: "private"`.

```raku
# Reads the world underneath it -- never cache this.
$server.resource: 'config://app',
    name => 'App Config',
    handler => -> :%args { '/etc/app.json'.IO.slurp };

# Ships with the distribution and is the same for every caller.
$server.resource: 'docs://handbook',
    name        => 'Handbook',
    ttl-ms      => 86_400_000,   # a day
    cache-scope => 'public',
    handler     => -> :%args { $handbook-text };
```

A modern `resources/read` then carries the hints on the result:

    config://app      { "ttlMs": 0,        "cacheScope": "private" }
    docs://handbook   { "ttlMs": 86400000, "cacheScope": "public"  }

`:ttl-ms` must be zero or more and `:cache-scope` must be `public` or `private`, or registration dies naming the offending resource. Both options are also accepted by the registrar a toolkit's `register` is handed, so a pack can declare cacheability for its own resources and have it survive prefixing. Legacy clients never see either field.

Prompts
-------

Prompts are pre-defined templates for the user.

```raku
$server.prompt: 'review',
    description => 'Code review prompt',
    arguments => [
        { name => 'code', description => 'Code to review', required => True },
    ],
    handler => -> :%args { "Please review:\n{%args<code>}" };
```

One-shot setup
--------------

`MCP::Server.new(:tools[...])` builds and plugs toolkits declaratively instead of calling `.plug` once per toolkit by hand. Each entry in the list may be:

  * A bare or fully-qualified toolkit name (`Str`) — instantiated via `.from-config({})` (or `.new` if the toolkit doesn't provide `from-config`) and plugged with no config and no explicit prefix.

  * A `Pair` of name/instance `=` config hash — the config's reserved `prefix` key, if present, is pulled out and passed to `.plug`; the rest goes to `.from-config`. When the key side is already an instance, the config hash may contain only `prefix` — anything else dies, since an instance is already built and has nothing left to configure.

  * A toolkit instance on its own — plugged as-is, unprefixed (unless it declares a `default-prefix`).

Name resolution matches `load-toolkit-class`: a bare name (no `::`) resolves under `MCP::Server::Tool::`, so `'FileSystem'` loads `MCP::Server::Tool::FileSystem`; a name containing `::` is used verbatim. If the module can't be loaded — typically because the distribution isn't installed — the error names the module and suggests the `zef install` command to fix it.

```raku
my $server = MCP::Server.new(
    :name<my-tools>,
    :tools[
        'Echo',
        FileSystem => { root => '/data', prefix => 'docs' },
    ],
);
```

Loading the same toolkit twice under different prefixes is exactly what you'd expect — repeat the entry with different config:

```raku
:tools[
    FileSystem => { root => '/docs',  prefix => 'docs'  },
    FileSystem => { root => '/build', prefix => 'build' },
],
```

Config files
------------

`MCP::Server.from-config($path)` builds a whole server — name, version, instructions, and every toolkit — from a single JSON file. It carries the same information `:tools` does, in a form that doesn't require a line of Raku:

```json
{
  "name": "my-tools",
  "version": "1.0",
  "instructions": "Reads and writes files under two roots.",
  "tools": {
    "FileSystem": { "root": "/docs" },
    "FileSystem#build": { "root": "/build", "prefix": "build" },
    "Shell": { "allow": ["git", "ls"] }
  }
}
```

```raku
my $server = MCP::Server.from-config('server-config.json');
$server.run;
```

Keys ending in `#alias` (like `FileSystem#build` above) load the same toolkit more than once with different settings: the part before `#` is the toolkit name, and the whole key — alias included — just has to be unique inside the `tools` object, since JSON object keys can't repeat on their own. The reserved `prefix` key inside each toolkit's config object works exactly as it does for `:tools` — it's pulled out and passed to `.plug`, and `from-config` on the toolkit itself never sees it.

Top-level keys are limited to `name`, `version`, `instructions`, `tools`, and `http` (the last of which turns on the Streamable HTTP transport — see "HTTP transport" below). `name` is required and must be a non-empty string. Anything else that's wrong — an unknown top-level key, invalid JSON, a non-object top level, a non-object `tools` section, a non-object per-toolkit config, or a toolkit's own config validation failure (unknown/missing keys) — dies with the config file's path folded into the message, so errors from deeply nested toolkit config are still traceable back to the file that caused them.

raku-mcp
--------

Installing this distribution also installs a `raku-mcp` command — a thin CLI front end (`MCP::Server::CLI`) for assembling a server out of toolkit packs without writing any Raku at all:

    raku-mcp --config=PATH
    raku-mcp --tool=SPEC [--tool=SPEC ...] [--name=STR] [--version=STR] [--instructions=STR]
    raku-mcp --tool=SPEC --http=PORT [--host=ADDR] [--http-path=PATH] [--allow-origin=ORIGIN ...]
    raku-mcp --describe=SPEC
    raku-mcp --help

  * `--config=PATH` — load a JSON config file (see "Config files" above) and run it.

  * `--tool=SPEC` — load one toolkit and run; repeatable to load several. `SPEC` is a bare or qualified toolkit name, optionally followed by `=` and an inline JSON config object. A `"prefix"` key inside that JSON namespaces the toolkit, same as everywhere else.

  * `--name=STR`, `--version=STR`, `--instructions=STR` — set the server's identity when using `--tool` (meaningless with `--config`, which takes these from the file instead).

  * `--http=PORT` — serve the Streamable HTTP transport on `PORT` instead of stdio. `--host=ADDR`, `--http-path=PATH`, and the repeatable `--allow-origin=ORIGIN` configure it; see "HTTP transport" below for what each one does and for the equivalent config-file section.

  * `--describe=SPEC` — print a toolkit's config schema and exit, without starting a server.

  * `--help` — print usage and exit.

`--config` and `--tool` are mutually exclusive with each other and with `--describe`. Every flag is `--name=value`; there is no space-separated `--name value` form. `--host`, `--http-path`, and `--allow-origin` only mean anything to the HTTP transport, so passing one without `--http` (and without a `--config` whose file might turn HTTP on) is an error rather than a setting that quietly does nothing.

    $ raku-mcp --tool=FileSystem={"root":"/docs"} --tool=Shell={"allow":["git"]}
    $ raku-mcp --config=server-config.json

`--describe=Name` on its own prints only the config schema — the attribute list a toolkit accepts, with each one's type and whether it's required:

    $ raku-mcp --describe=FileSystem
    Toolkit: MCP::Server::Tool::FileSystem
    Config:
      root  IO::Path()  required

Adding `={...}` — even `={}` — builds the toolkit with that config and additionally lists every tool, prompt, and resource it registers, since listing them needs an actual instance to call `tools/list` etc. against:

    $ raku-mcp --describe=FileSystem={"root":"/docs"}
    Toolkit: MCP::Server::Tool::FileSystem
    Config:
      root  IO::Path()  required

    Tools:
      read - Read the contents of a file
      ...

All diagnostics — usage errors, unloadable toolkits, malformed JSON — go to stderr; stdout carries only `--help`/`--describe` output and, once `serve` starts a transport, the MCP protocol stream itself. This matters because MCP clients (Claude Code included) read stdout as the protocol channel — anything unexpected printed there breaks the connection.

Point Claude Code at a config file (note the single `--config=...` token — `parse-args` doesn't accept a separate value argument):

```json
{
  "mcpServers": {
    "my-tools": {
      "command": "raku-mcp",
      "args": ["--config=/absolute/path/to/server-config.json"]
    }
  }
}
```

Writing a tool pack
-------------------

A tool pack is its own zef distribution, named `MCP::Server::Tool::*` (e.g. `MCP::Server::Tool::FileSystem`), providing one class that does `MCP::Server::Toolkit`. Conventions that keep a pack interchangeable with `:tools`, `from-config`, and `raku-mcp --describe`:

  * Namespace as `MCP::Server::Tool::Name`, one toolkit class per distribution, so bare-name resolution (`'Name'` resolving to `MCP::Server::Tool::Name`) works without qualification.

  * `does MCP::Server::Toolkit`, implementing `register($registrar)` and, when the pack should namespace by default, `default-prefix`.

  * Config is public attributes — nothing more. `from-config` derives its accepted keys directly from `self.^attributes(:all).grep(*.has_accessor)`, so every public attribute IS the config schema; there's no separate schema to keep in sync, and coercive types (`IO::Path()`) or defaults behave exactly as they would on any other class.

  * Any setting that gates what the toolkit is allowed to touch — a filesystem root, an allowlist of shell commands, a credential with write access — should be `is required`. `from-config` then refuses to build an instance without it, so a pack can't end up running wide open just because a config file forgot a key.

  * Depend on `"MCP::Server:auth<zef:apogee>"`, not on any specific server that happens to embed it — a well-behaved pack works equally as a one-shot `:tools` entry, a `.plug`-ed instance, or a config-file entry in any host server.

Two reference packs ship as separate distributions and are worth reading as examples of the conventions above:

  * `MCP::Server::Tool::FileSystem` — root-confined file access.

  * `MCP::Server::Tool::Shell` — allowlisted command runner.

Examples
--------

  * `examples/echo-server.raku` — Minimal echo and reverse tools

  * `examples/weather-server.raku` — Weather via wttr.in

  * `examples/file-server.raku` — File system tools using tool groups

  * `examples/strawberry-server.raku` — The tool LLMs wish they had

  * `examples/toolkit-server.raku` — Plugging installed tool packs (FileSystem, Shell) into one server alongside an inline tool

  * `examples/server-config.json` — A JSON config for `from-config`, including an aliased toolkit entry

Protocol
--------

Two MCP protocol eras are spoken at once, and which one a message belongs to is worked out from the message itself rather than from a mode flag:

  * `2025-11-25` — the **legacy** era. Session-shaped: the client opens with `initialize`, follows up with `notifications/initialized`, and the connection then carries state (whether the handshake finished, what log level was asked for) until it hangs up.

  * `2026-07-28` — the **modern** era. Stateless: there is no handshake and no session, every request describes itself through `params._meta`, and the server keeps nothing at all between messages.

The 2026-07-28 specification explicitly permits a dual-era server to serve both eras concurrently on the same endpoint, and that is what one `MCP::Server` instance does. Nothing has to be configured for it: a 2025-11-25 client and a 2026-07-28 client can be talking to the same process at the same time and neither will notice the other.

### Which era a message belongs to

Four rules, applied per message, in this order:

  * 1. `initialize` is **always** legacy. The method does not exist in 2026-07-28 at all, so a stray `_meta` on it is ignored rather than treated as a contradiction.

  * 2. `server/discover` is **always** modern. It exists only in 2026-07-28, and it is the bootstrap probe a client uses to find out what the server speaks, so it is answerable with no `_meta` whatsoever.

  * 3. Otherwise, a `params._meta` carrying `io.modelcontextprotocol/protocolVersion` makes the message modern.

  * 4. Anything else is legacy.

```raku
my $server = MCP::Server.new(:name<my-tools>);
$server.tool: 'greet', handler => -> :%args { 'Hi' };

# 1. initialize is legacy, so the answer names the legacy version.
$server.handle-request({ jsonrpc => '2.0', id => 1, method => 'initialize', params => {} });
#    result.protocolVersion => '2025-11-25'

# 2. server/discover is modern even with no _meta at all.
$server.handle-request({ jsonrpc => '2.0', id => 2, method => 'server/discover' });
#    result.supportedVersions => ['2026-07-28'], result.resultType => 'complete'

# 3. _meta's protocol version makes anything else modern.
$server.handle-request({
    jsonrpc => '2.0', id => 3, method => 'tools/list',
    params  => { _meta => { 'io.modelcontextprotocol/protocolVersion' => '2026-07-28' } },
});
#    result.resultType => 'complete', result.ttlMs => 3600000,
#    result.cacheScope => 'private'

# 4. The same call without _meta is legacy: a bare list, no envelope.
$server.handle-request({ jsonrpc => '2.0', id => 4, method => 'tools/list' });
#    result.tools only -- no resultType, no ttlMs
```

### The legacy era (2025-11-25)

  * `initialize` / `notifications/initialized` handshake, answering with the server's capabilities — `tools`, `resources`, `prompts` for whatever is actually registered, plus `logging`.

  * `tools/list`, `tools/call`, `resources/list`, `resources/read`, `prompts/list`, `prompts/get`.

  * `ping`, answered with an empty result.

  * `logging/setLevel`, which sets the session's minimum severity. Levels are the RFC 5424 eight (`debug`, `info`, `notice`, `warning`, `error`, `critical`, `alert`, `emergency`); anything else comes back as `-32602` listing the ones that work. The advertised `logging` capability is therefore honest — earlier releases advertised it without implementing the method.

  * Logging via `notifications/message`, emitted on the transport once the client has said it is initialized and only at or above the level it asked for.

### The modern era (2026-07-28)

  * `server/discover` replaces the handshake. It reports `supportedVersions`, `capabilities`, the server's `instructions` if it has any, and the `ttlMs`/`cacheScope` for which those answers hold.

  * Every request must carry `params._meta.io.modelcontextprotocol/protocolVersion`; `...clientInfo` and `...clientCapabilities` are optional, and `...logLevel` opts that one request into log notifications. The one exception is `server/discover`, which is how a client finds out what to put there in the first place.

  * Every result carries `resultType`. It is `complete` unless the handler stopped to ask the client something, in which case the round is answered `input_required` — see "Elicitation" below.

  * Every result carries `_meta.io.modelcontextprotocol/serverInfo`.

  * `tools/list`, `prompts/list`, `resources/list` and `resources/read` carry `ttlMs` and `cacheScope`. The three listings use the server-wide values (see "Modern-era server options"); a read uses whatever the resource declared (see "Cacheability" above).

  * Listings are ordered deterministically — tools and prompts by name, resources by URI — in both eras, because Raku hash order is not stable and a cache keyed on the response body deserves better.

  * `initialize`, `ping` and `logging/setLevel` are gone, and answer `-32601` to a modern caller. Liveness belongs to the transport now, and the log level travels per request.

A modern `tools/call` and the answer it gets:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "tools/call",
  "params": {
    "name": "greet",
    "arguments": { "name": "Ada" },
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28",
      "io.modelcontextprotocol/clientInfo": { "name": "demo-client", "version": "0.1" },
      "io.modelcontextprotocol/clientCapabilities": {},
      "io.modelcontextprotocol/logLevel": "info"
    }
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "content": [ { "type": "text", "text": "Hello, Ada!" } ],
    "resultType": "complete",
    "_meta": {
      "io.modelcontextprotocol/serverInfo": { "name": "my-tools", "version": "1.2.0" }
    }
  }
}
```

Because that request opted in at `info`, anything the handler logs at `info` or above is delivered as a `notifications/message` on the same channel before the response — interleaved on stdout for stdio, as SSE events for HTTP. A request that omits `logLevel` gets no notifications at all: the spec says a server **must not** send them unasked, and the gating is per request, so one client's log lines can never surface on another's channel.

The same call against `tools/list` shows the cache metadata:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "tools": [ { "name": "greet", "description": "Greet someone by name", "inputSchema": { } } ],
    "ttlMs": 3600000,
    "cacheScope": "private",
    "resultType": "complete",
    "_meta": {
      "io.modelcontextprotocol/serverInfo": { "name": "my-tools", "version": "1.2.0" }
    }
  }
}
```

### Version negotiation

Alongside the standard JSON-RPC codes (`-32700` parse error, `-32600` invalid request, `-32601` method not found, `-32602` invalid params, `-32603` internal error), 2026-07-28 defines three of its own:

  * `-32020` **header mismatch** — a transport's routing headers disagree with the body they claim to describe. Only the HTTP transport can raise this one.

  * `-32021` **missing required client capability** — exported as a constant for handlers and transports that need it. This server never raises it: it asks nothing of its clients (see "Not supported").

  * `-32022` **unsupported protocol version** — the requested version is not one this server speaks.

`-32022` is the one clients are expected to recover from, so it always carries the way out in `data`:

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "error": {
    "code": -32022,
    "message": "Unsupported protocol version",
    "data": {
      "requested": "2027-01-01",
      "supported": ["2025-11-25", "2026-07-28"]
    }
  }
}
```

`data.supported` lists **every** version the server is configured for, legacy ones included, so a client that guessed too high can drop back rather than start over. A modern request with no `_meta` version at all gets the same error with `requested: null`.

### Modern-era server options

`:protocol-versions` restricts which eras an instance answers for; the default is both. `:discovery-ttl-ms` and `:cache-scope` set the cache metadata on the three catalog listings and on `server/discover`. An hour and `private` are the defaults: registration all happens before `run`, so the catalogs really are frozen for the life of the process and an hour is honest, while `private` is the safe reading for a server whose catalog might be user-specific.

```raku
my $server = MCP::Server.new(
    :name<my-tools>,
    :protocol-versions['2026-07-28',],   # modern clients only
    :discovery-ttl-ms(60_000),           # catalogs are good for a minute
    :cache-scope<public>,                # ...and the same for everyone
);
```

Restricting the list is enforced in both directions, and each direction gets the error that helps the client most. A modern-only server answers `initialize` with `-32022` rather than `-32601`, because the spec asks it to name what it does speak:

```json
{ "code": -32022, "message": "Unsupported protocol version",
  "data": { "requested": "2025-11-25", "supported": ["2026-07-28"] } }
```

...and a `:protocol-versions['2025-11-25',]` server answers any request carrying a modern `_meta` version with the mirror image of that. An unknown version in the list is refused at construction time:

```raku
MCP::Server.new(:name<x>, :protocol-versions['2024-01-01',]);
# dies: Unknown protocol version(s) for MCP server 'x': 2024-01-01.
# Supported: 2025-11-25, 2026-07-28
```

### Not supported

Two parts of 2026-07-28 are deliberately absent. Each is a consequence of what this framework is, not a gap to be filled in later:

  * **`subscriptions/listen`**. Subscriptions only mean something if the server emits change notifications, and this one emits none and advertises no `listChanged` capability. Rather than accept a subscription it would never honour, it answers `-32601` (`404` over HTTP) like any other method it does not have.

  * **Extensions**. `server/discover` reports no `extensions` key because there are none; the same goes for the `x-mcp-header` parameter annotations, which would need a schema-annotation mechanism the tool registration API does not have.

Transport
---------

Default transport is stdio (stdin/stdout), and it serves both eras. Custom stream transports can be created by implementing the `MCP::Server::Transport` role:

```raku
use MCP::Server::Transport;

class MyTransport does MCP::Server::Transport {
    method read-message(--> Str) { ... }
    method write-message(Str:D $msg) { ... }
}

$server.run(:transport(MyTransport.new));
```

`run` reads messages until the stream ends, dispatches each one, and writes the responses back. Notifications raised while a request is in flight are written on the same stream, ahead of the response they belong to.

### Building request/response transports

The role above is stream-shaped: two methods, no headers, no status codes, no pairing of a request with its answer. A transport that speaks in discrete request/response pairs — the built-in Streamable HTTP transport, a message queue, an in-process bridge — wants a different seam, and `MCP::Server` exposes four transport-free methods for it.

```raku
method handle-modern-request(%msg, :&notify, Promise :$cancelled --> Hash)
method server-info(--> Hash)               # { name, version }
method discovery-document(--> Hash)        # server/discover's body, unframed
method modern-protocol-versions(--> List)  # configured versions in the modern era
```

`handle-modern-request` takes a parsed message and returns the response hash. Its contract:

  * The era is **forced** modern rather than detected, because a request/response transport has no session to hang a legacy one on. A legacy-shaped message therefore gets a modern answer: `-32601` for `initialize`/`ping`/`logging/setLevel`, `-32022` when `_meta` has no usable protocol version.

  * A notification — a body with no `id` — is dispatched for its side effects and answered with an **empty Hash**, since JSON-RPC forbids replying to one. Transports turn that into whatever "accepted, nothing to say" looks like for them (`202` over HTTP).

  * `:&notify` is called **synchronously, on the calling thread**, zero or more times, before the method returns. That is what lets a live stream carry a handler's log lines as they happen rather than after the fact. Leave it out and the request's notifications are dropped.

  * `:$cancelled` is a Promise the transport keeps for "the caller has walked away". It reaches handlers through `$*MCP-REQUEST-CONTEXT.cancelled`.

  * It touches no server state, so concurrent calls are safe as far as this class is concerned. **Your handlers still have to be thread-safe themselves** — see the warning under "HTTP transport".

`discovery-document` is static for the life of the process, so a transport may cache it (it carries its own `ttlMs`/`cacheScope`), and `modern-protocol-versions` is what a transport validates a version header against.

```raku
# A minimal in-process bridge.
my %response = $server.handle-modern-request(
    {
        jsonrpc => '2.0', id => 5, method => 'tools/call',
        params  => {
            name => 'crunch', arguments => { },
            _meta => {
                'io.modelcontextprotocol/protocolVersion' => '2026-07-28',
                'io.modelcontextprotocol/logLevel'        => 'debug',
            },
        },
    },
    notify => -> %notification { @log.push: %notification },
);
```

### The request context

`$*MCP-REQUEST-CONTEXT` is bound to an immutable `MCP::Server::Context` around every dispatch, so a handler can reach it without any change to its signature, and every thread sees its own request's context. The two methods handlers actually want:

  * `wants-log($level)` — would a message at `$level` reach this client? Worth asking before building an expensive diagnostic string, since in the modern era the answer is no unless the request opted in through `_meta` `logLevel`.

  * `cancelled` — has the caller given up? The server never interrupts a running handler, so a long loop that wants to be interruptible has to look.

  * `elicit($message, ...)` — ask the human on the other end of the client a question and block until they answer. See "Elicitation" below.

  * `can-elicit` — is there anybody to ask? Worth checking in a handler that can work either way, rather than catching `elicit`'s exception.

`era`, `protocol-version`, `log-level`, `client-info` and `client-capabilities` are readable too, for a handler that wants to adapt to what the client said about itself.

```raku
$server.tool: 'crunch',
    description => 'Chew through a big pile of work',
    handler => -> :%args {
        my $ctx = $*MCP-REQUEST-CONTEXT;
        my $done = 0;
        for @work -> $item {
            last if $ctx.cancelled;
            $server.log('debug', "item {$item.id}") if $ctx.wants-log('debug');
            crunch($item);
            $done++;
        }
        "crunched $done of {@work.elems}";
    };
```

Outside a request — during startup, say — `$*MCP-REQUEST-CONTEXT` is undefined, and `$server.log` falls back to the legacy transport-wide channel. Logging always writes to `$*ERR` whatever else happens to it, so nothing is ever lost just because no client was listening.

### Notifications that are not log lines

`$server.notify(%notification)` is the delivery half of `log` on its own: it takes a whole notification — `{ method => ..., params => ... } `, as `MCP::Server::Protocol`'s `notification` sub builds it — routes it exactly as `log` would, and returns `True` if some channel took it.

```raku
use MCP::Server::Protocol;

$server.notify(notification('notifications/progress', {
    progressToken => $token, progress => $done, total => @work.elems,
}));
```

The two things it does not do are the point of it. It never echoes to `$*ERR`, so a background job streaming its output to a client does not also spray the host process's terminal; and it applies no level gating, because `notifications/progress` has no level to gate on and a job's output should not be silenced by a `logging/setLevel` made for log lines. **Gating is therefore the caller's job**: a `notifications/message` raised this way should be sent only when `$*MCP-REQUEST-CONTEXT.wants-log($level)` agrees, since the 2026-07-28 rule that a server **must not** log for a request that did not opt in is not enforced here.

It is safe to call from any thread — the bundled transports serialise their writes — which is what makes it usable from a `Supply.interval` flusher or a worker that outlives the request that started it. A modern request's notification still goes to that request's channel and nowhere else; out of a request the legacy rules apply, so nothing is sent before the client has said it is initialized.

The bridge is the one exception to "outside a request": a tool called through `execute-tool-calls` gets a legacy-era context with no notification sink, so a handler that reads the context works there too rather than dying on an undefined dynamic variable.

Elicitation
-----------

A handler can stop in the middle of its work and ask the human on the other end of the client a question:

```raku
$server.tool: 'deploy',
    description => 'Deploy the current build',
    handler => -> :%args {
        my $answer = $*MCP-REQUEST-CONTEXT.elicit(
            'Which environment should I deploy to?',
            properties => {
                env => {
                    type        => 'string',
                    description => 'Target environment',
                    enum        => <staging production>.List,
                },
                notes => { type => 'string', description => 'Release notes' },
            },
            required => ['env',],
        );

        # A refusal is an answer, not a malfunction.
        return 'Nothing deployed.' unless $answer.accepted;

        deploy($answer.content<env>, notes => $answer.content<notes> // '');
        "Deployed to {$answer.content<env>}.";
    };
```

`elicit` returns an `MCP::Server::Elicitation::Outcome`: `action` (`accept`, `decline` or `cancel`), the predicates `accepted`, `declined` and `cancelled`, and `content` — the form the user filled in, populated only for an accept. Nothing here throws when the user says no, because a user saying no is the system working.

Ask more than once and each question is a separate round trip; ask from several threads at once and they go out together in one.

### What goes on the wire

Elicitation is the 2026-07-28 **multi round-trip request** pattern (MRTR). The call the handler is serving is answered with a question rather than a result:

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "resultType": "input_required",
    "inputRequests": {
      "q1": {
        "method": "elicitation/create",
        "params": {
          "mode": "form",
          "message": "Which environment should I deploy to?",
          "requestedSchema": {
            "type": "object",
            "properties": {
              "env": { "type": "string", "enum": ["staging", "production"] },
              "notes": { "type": "string", "description": "Release notes" }
            },
            "required": ["env"]
          }
        }
      }
    },
    "requestState": "mrtr-3-1f0c…",
    "_meta": { "io.modelcontextprotocol/serverInfo": { } }
  }
}
```

The client asks its user and sends the **same request again** — a new JSON-RPC id, the original `params`, plus the answers keyed by the server's own ids and the `requestState` echoed back byte for byte:

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "tools/call",
  "params": {
    "name": "deploy",
    "arguments": { },
    "inputResponses": {
      "q1": { "action": "accept", "content": { "env": "staging" } }
    },
    "requestState": "mrtr-3-1f0c…",
    "_meta": { "io.modelcontextprotocol/protocolVersion": "2026-07-28" }
  }
}
```

Only `tools/call`, `resources/read` and `prompts/get` may be answered this way — the spec names those three and no others — and only for a client that declared `elicitation: { form: {} }` in its `_meta` `clientCapabilities`. A handler that asks anyway gets an exception saying which of the two conditions failed, which for a tool becomes an `isError` result. Check `can-elicit` first if the handler can do something useful without an answer.

Each round is an independent request with its own notification channel, its own `logLevel` opt-in and its own cancellation signal, and the context delegates accordingly: a log line raised after the handler resumes goes out on the round that resumed it. The original request's disconnection is **not** treated as cancellation — it was answered the moment the call parked, so its stream closing is expected.

### How the handler survives the gap

The handler is **parked**, not restarted. It runs on a thread of its own and blocks in `await`, which inside a `start` block suspends the continuation without pinning a pool thread. Everything it had already done stays done — which a restart-based implementation could not promise, since it would re-run every side effect up to the question.

Two consequences worth knowing about:

  * A parked call does not survive a restart of the process. The token names an in-memory rendezvous, not a serialised continuation.

  * Behind a load balancer, the retry must reach the instance that asked. Route on `requestState` or pin the session.

Only a modern-era request, on one of the three eligible methods, from a client that declared the capability is dispatched onto its own thread. Everything else — stdio, legacy clients, clients that declared nothing — runs synchronously on the caller's thread exactly as it always has.

### Timeouts, TTL and capacity

  * `$ctx.elicit(..., :timeout(30)) ` bounds one question: when it runs out the question is withdrawn and the answer is a `cancel`.

  * `MCP::Server.new(:elicitation-ttl(300)) ` bounds the wait for a client that never comes back. When it expires the call is abandoned: `elicit` throws inside the handler, which unwinds through its own error path, and the token stops working.

  * `MCP::Server.new(:max-pending-elicitations(64)) ` bounds how many calls may sit parked at once. Past that, asking is refused with an error result rather than queued behind clients that may never answer.

  * `.pending-elicitations` reports how many are parked right now, for a health endpoint or a test.

### When there is no client to ask

`:&on-elicit` is the fallback for the paths where the "client" cannot be asked anything: a legacy-era client, the LLM tool bridge, or a handler called directly from your own code. It takes the same ElicitRequest the client would have received and returns an ElicitResult:

```raku
my $server = MCP::Server.new(
    :name<deployer>,
    on-elicit => -> %request {
        say %request<params><message>;
        my $answer = prompt('> ');
        $answer.defined && $answer.trim.chars
            ?? { action => 'accept', content => { env => $answer.trim } }
            !! { action => 'decline' };
    },
);
```

Anything it returns that is not an ElicitResult is read as a decline. A modern client that declared the capability always wins over it: the human at the other end of the protocol is a better answer than a callback in the server process.

One caveat on that example: `prompt` reads stdin and writes stdout, so it only works in a server that does not own them. Over stdio those two are the protocol, and writing a question to stdout corrupts it — a stdio server's fallback has to ask somewhere else (a GUI, a queue, a policy table), or the server has to run over HTTP, as `MCP::Server::Tool::Ask`'s example does.

### A note on the token

`requestState` is a monotonic counter plus 128 bits from `rand`. Raku's core has no CSPRNG, and `rand` is a Mersenne Twister, so a token is not unguessable to an attacker who has seen a few of them. What guessing one buys is the ability to answer somebody else's question once, within the TTL, on the right method — no data comes back out — and it is defended in depth: claims are single use, pinned to the method that minted the token, bounded by the TTL and capped in number. Binding to a real CSPRNG is a tracked follow-up rather than something this release pretends to have.

HTTP transport
--------------

`MCP::Server::HTTP` is the 2026-07-28 Streamable HTTP transport: one POST-only endpoint, no sessions, no server-initiated stream, every request self-describing. It is a sibling of the server rather than a `Transport` role implementation, for the reasons in "Building request/response transports" above.

```raku
use MCP::Server;
use MCP::Server::HTTP;

my $server = MCP::Server.new(:name<my-tools>, version => '1.0');

$server.tool: 'greet',
    description => 'Greet someone by name',
    params => { name => { type => 'string', required => True } },
    handler => -> :%args { "Hello, {%args<name>}!" };

MCP::Server::HTTP.new(:$server, :port(8080)).run;
```

    $ curl -s http://127.0.0.1:8080/mcp \
        -H 'Content-Type: application/json' \
        -H 'MCP-Protocol-Version: 2026-07-28' \
        -H 'Mcp-Method: tools/call' \
        -H 'Mcp-Name: greet' \
        -d '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{
             "name":"greet","arguments":{"name":"Ada"},
             "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}'
    {"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"Hello, Ada!"}],
     "resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{
     "name":"my-tools","version":"1.0"}}}}

The three routing headers are what let a proxy route and rate-limit MCP traffic without parsing bodies: `MCP-Protocol-Version` and `Mcp-Method` are required on every request, and `Mcp-Name` is required for `tools/call`, `resources/read` and `prompts/get`. All of them are checked against the body, and disagreement is a `400` with `-32020` rather than a silently preferred half of the request. A value that cannot travel in a header as-is — a resource URI with an accent in it, say — may use the `=?base64?...?=` sentinel, which is decoded before the comparison.

### Starting and stopping

  * `start` returns as soon as the listener is up, so a test or a larger application can carry on. Calling it twice on one instance dies: one instance means one listener.

  * `stop` shuts the listener down and lets in-flight responses finish. It is safe on an instance that was never started, which makes it usable as a `LEAVE` or `END` handler.

  * `run` is `start`, then block until SIGINT (or SIGTERM where the platform has one — Windows does not), then `stop`. This is what the CLI uses.

### Options

  * `:$server` (required) — the `MCP::Server` whose catalogs and handlers are exposed. Register everything before `start`: the transport treats it as frozen.

  * `:$host` — default `127.0.0.1`. See "Security" below before changing it.

  * `:$port` — default `8080`. Must be 1..65535; `0` is refused rather than silently rebound to whatever the OS picks, since nothing could then tell you which port that was.

  * `:$path` — default `mcp`. Surrounding slashes are normalised away and more than one segment is fine, so `'/api/mcp/'` and `'api/mcp'` both serve `http://host:port/api/mcp`.

  * `:@allowed-origins` — extra browser origins to accept, as exact `Str`s or `Regex`es. Anything else dies at construction.

  * `:$allow-no-origin` — default `True`; whether a request with no `Origin` header at all is accepted.

  * `:$keepalive` — default `15` seconds between SSE keepalive comments, which stop proxies and impatient clients from tearing down a stream whose handler is still thinking. Must be greater than zero.

  * `:$disconnect-poll` — default `0.25` seconds between the client-liveness probes that turn a hangup into `$*MCP-REQUEST-CONTEXT.cancelled`. See "Cancellation and thread safety" below. Must be greater than zero.

### From the command line

    $ raku-mcp --tool=FileSystem={"root":"/docs"} --http=8080
    $ raku-mcp --tool=FileSystem={"root":"/docs"} --http=8080 \
          --host=0.0.0.0 --http-path=api/mcp \
          --allow-origin=https://app.example.com --allow-origin=https://admin.example.com

The same settings live in the config file's optional `http` section, so a `--config` server can serve HTTP without any flags at all:

```json
{
  "name": "my-tools",
  "tools": { "FileSystem": { "root": "/docs" } },
  "http": {
    "port": 8080,
    "host": "127.0.0.1",
    "path": "api/mcp",
    "allowedOrigins": ["https://app.example.com"]
  }
}
```

Only those four keys are accepted, and each is validated as the file is read — a port outside 1..65535, an empty `host`, an `allowedOrigins` that is not an array of strings — so a typo is reported with the config file's path attached rather than at some later point in startup.

Where both a flag and the file have something to say, **the command line wins**: `--http=9000` against the file above serves on 9000, keeping the file's host and path. `--allow-origin` is the exception that adds rather than replaces — flags and file entries are concatenated, since "also allow this origin" is what you meant. Merely having an `http` section is enough to select the transport; `--http=PORT` on its own is enough without one.

### JSON or SSE

Whether a request comes back as one JSON object or as an event stream is decided lazily, per request:

  * A client whose `Accept` does not include `text/event-stream` always gets a single `application/json` object. Anything the handler logs goes no further than the server's own `$*ERR`; the spec leaves that choice to the server.

  * A client that does accept `text/event-stream` gets a stream **only if the handler actually says something**. The handler runs while the transport waits for whichever comes first: it finishing, or its first notification. Finishing first means a plain JSON response, so a quiet request never pays for a stream.

  * Once committed, the stream carries the notifications as SSE events in the order they were raised, then the response as a final event, then closes. `X-Accel-Buffering: no` and `Cache-Control: no-store` go out with it.

Both conditions have to hold for a notification to reach a client: the `Accept` header **and** the request's `_meta` `logLevel` opt-in. A handler that logs on behalf of a request that never asked for logs produces no events, and so no stream.

Calling a `slow-count` tool that logs `"step $_"` as it goes, with both conditions met:

    $ curl -sN http://127.0.0.1:8080/mcp \
        -H 'Content-Type: application/json' \
        -H 'Accept: text/event-stream' \
        -H 'MCP-Protocol-Version: 2026-07-28' \
        -H 'Mcp-Method: tools/call' -H 'Mcp-Name: slow-count' \
        -d '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{
             "name":"slow-count","arguments":{"to":3},
             "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                      "io.modelcontextprotocol/logLevel":"info"}}}'

    data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"my-tools","data":"step 0"}}

    data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"my-tools","data":"step 1"}}

    data: {"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"my-tools","data":"step 2"}}

    data: {"jsonrpc":"2.0","id":8,"result":{"content":[{"type":"text","text":"counted to 3"}],"resultType":"complete","_meta":{"io.modelcontextprotocol/serverInfo":{"name":"my-tools","version":"1.0"}}}}

### Modern era only

HTTP speaks 2026-07-28 and nothing else. `initialize`, `ping` and `logging/setLevel` answer `-32601` here, and a request whose `MCP-Protocol-Version` header is not a modern version this server is configured for is refused with `400` and `-32022` before its body is even parsed. Stdio remains dual-era, so a legacy client is not locked out of the framework — only out of this transport.

One consequence worth knowing: every other method needs a matching `_meta` protocol version in the body, since `MCP-Protocol-Version` is compared against it and a header with nothing to match is a `-32020`. `server/discover` is exempt — the `MCP-Protocol-Version` header is still required, but the body needs no `_meta` at all, since it is the bootstrap probe a client sends before it can know what version to claim.

### Status codes

  * `200` — a response, including one carrying a JSON-RPC error object. The error is the payload, not the transport's problem.

  * `202` — a well-formed notification (no `id`). Dispatched, no body, as JSON-RPC requires.

  * `400` — `-32020` header mismatch or missing routing header, `-32022` unsupported version, `-32700` unparseable body, `-32600` a JSON-RPC batch (the modern era sends one message per request).

  * `403` — `Origin` refused. Checked first, before anything with a side effect.

  * `404` — `-32601`, which covers unknown methods and `subscriptions/listen`. A method that does not exist is a resource that does not exist.

  * `405` — anything but POST, with `Allow: POST`.

  * `415` — a body that is not `application/json`.

  * `500` — `-32603`, as a JSON-RPC object. The endpoint never answers with an HTML error page; an MCP client is owed JSON whatever went wrong.

Stray `Mcp-Session-Id` and `Last-Event-ID` headers — artifacts of an older Streamable HTTP shape that this transport never emits — are ignored outright rather than held against a client carrying them over.

### Cancellation and thread safety

A client hanging up is the only cancellation signal this protocol has — whether it closed the response stream, cancelled the request, or the connection died under it. When it happens, `$*MCP-REQUEST-CONTEXT.cancelled` flips to `True` and the eventual result is discarded. **The server never interrupts a running handler**: a synchronous one that never looks runs to completion, holding its thread. Anything long-running should poll.

Nothing pushes a disconnect at the endpoint — a Cro route is handed a request, not a connection lifetime — so it is checked for, on the `disconnect-poll` interval (a quarter of a second by default), with a zero-byte write that puts nothing on the wire. Lower it for handlers that should give up the moment their caller does; raise it to trade latency for syscalls. Detection is exact rather than heuristic: a socket that has read EOF from its peer is closed, so a client that has hung up could not have been sent the answer anyway. Behind TLS the probe cannot tell, and cancellation then falls back to the slower signal — the write that fails when the handler finally answers — so a handler on a TLS endpoint may never see the flag at all.

```raku
$server.tool: 'reindex',
    description => 'Rebuild the search index',
    handler => -> :%args {
        my $ctx = $*MCP-REQUEST-CONTEXT;
        my $n = 0;
        for @documents -> $doc {
            last if $ctx.cancelled;   # cheap, and the only way out
            reindex-document($doc);
            $n++;
        }
        "indexed $n of {@documents.elems} documents";
    };
```

**Handlers run concurrently.** Cro dispatches each request on its thread pool, so two calls to the same tool can be in flight at once — which never happened over stdio, where messages are handled one at a time. The framework holds up its end (catalogs are frozen before `start`, the modern path mutates no server state, each request's notifications are routed to that request's channel, and `$*ERR` writes are locked so log lines cannot shear), but shared state inside *your* handlers is yours to protect. A tool that appends to a file, mutates a lexical hash, or talks to a client library that is not thread-safe needs a `Lock` — before it is exposed over HTTP, not after.

### Security

The endpoint speaks plain HTTP and binds `127.0.0.1` by default. Both defaults are deliberate.

**Origin policy.** A loopback server is reachable from any web page the user happens to have open, and DNS rebinding turns "reachable" into "scriptable". The `Origin` header is the defence, and the policy is:

  * No `Origin` at all — allowed by default (`:allow-no-origin`). Non-browser MCP clients do not send one, and a browser always attaches one to the cross-origin POST an attack would have to use, so this admits the clients that cannot be attacked this way without admitting the ones that can. Set `:!allow-no-origin` if every client of yours is a browser.

  * `http(s)://localhost`, `http(s)://127.0.0.1`, `http(s)://[::1]`, any port — always allowed. This is the page-under-development case.

  * Anything else — refused with `403` unless it is in `:@allowed-origins`.

```raku
MCP::Server::HTTP.new(
    :$server,
    allowed-origins => [
        'https://app.example.com',            # exact
        /^ 'https://' \w+ '.example.com' $/,  # or a pattern
    ],
).run;
```

`Origin` is not authentication — a non-browser client can send whatever it likes. It stops a web page from using the browser's own access to a loopback port; that is all it is for.

**Binding.** `127.0.0.1` means no firewall prompts and no accidental exposure. Changing `:host` to `0.0.0.0` publishes an unauthenticated endpoint that can run every tool you registered — do it only behind a reverse proxy that terminates TLS and authenticates, and read the auth hook below first.

**TLS.** There is no TLS here; terminate it in front. The one thing a proxy must get right is not buffering the event stream — the transport sends `X-Accel-Buffering: no`, which nginx honours, but say it plainly anyway:

    # nginx
    location /mcp {
        proxy_pass       http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host   $host;
        proxy_set_header Origin $http_origin;   # the allow-list needs to see it
        proxy_buffering  off;                   # SSE must not be buffered
        proxy_read_timeout 1h;                  # a long-running tool is not a hang
    }

    # Caddy
    mcp.example.com {
        reverse_proxy 127.0.0.1:8080 {
            flush_interval -1   # flush immediately: same reason as proxy_buffering off
        }
    }

Forward the browser's `Origin` as-is, and set `:allowed-origins` to the origins your front end really uses — the proxy's own hostname is not one of them.

**Authentication.** First-class auth is not built in, and `.routes` is the supported way to add your own. It hands back the endpoint as a `Cro::Transform` that can be mounted inside a larger Cro application, where any middleware you like gets a look at the request first:

```raku
use Cro::HTTP::Router;
use Cro::HTTP::Server;
use MCP::Server::HTTP;

my $mcp = MCP::Server::HTTP.new(:$server, :port(8080));

my $app = route {
    before {
        unless (request.header('Authorization') // '') eq "Bearer $token" {
            response.status = 401;
            content 'application/json', { error => 'unauthorized' };
        }
    }

    include $mcp.routes;   # the MCP endpoint, still at /mcp

    get -> 'healthz' { content 'text/plain', 'ok' }
}

Cro::HTTP::Server.new(:host<127.0.0.1>, :port(8080), application => $app).start;
```

Note that `.routes` is used instead of `.start`/`.run` here — the surrounding `Cro::HTTP::Server` owns the listener, so the transport must not open one of its own. The routes only match the endpoint's own path, so everything else in the block (`/healthz` above) still works.

Author
------

Matt Doughty

License
-------

Artistic-2.0

