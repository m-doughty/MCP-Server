[![Actions Status](https://github.com/m-doughty/MCP-Server/actions/workflows/test.yml/badge.svg)](https://github.com/m-doughty/MCP-Server/actions)

MCP::Server
===========

A framework for building MCP (Model Context Protocol) servers in Raku. Register tools, resources, and prompts — the framework handles the JSON-RPC 2.0 protocol, initialization handshake, and message dispatch.

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

Examples
--------

  * `examples/echo-server.raku` — Minimal echo and reverse tools

  * `examples/weather-server.raku` — Weather via wttr.in

  * `examples/file-server.raku` — File system tools

  * `examples/strawberry-server.raku` — The tool LLMs wish they had

Protocol
--------

Implements MCP protocol version `2025-11-25` over stdio:

  * JSON-RPC 2.0 message format

  * `initialize` / `initialized` handshake

  * `tools/list`, `tools/call`

  * `resources/list`, `resources/read`

  * `prompts/list`, `prompts/get`

  * `ping`

  * Logging via `notifications/message`

  * Full error handling with standard JSON-RPC error codes

Transport
---------

Default transport is stdio (stdin/stdout). Custom transports can be created by implementing the `MCP::Server::Transport` role:

```raku
use MCP::Server::Transport;

class MyTransport does MCP::Server::Transport {
    method read-message(--> Str) { ... }
    method write-message(Str:D $msg) { ... }
}

$server.run(:transport(MyTransport.new));
```

Author
------

Matt Doughty

License
-------

Artistic-2.0

