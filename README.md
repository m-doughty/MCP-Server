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

Tool Groups
-----------

Group related tools under a common prefix using `/` as separator:

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
# Registers as: file/read, file/list
```

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

`tools-for-llm` converts registered tools to the OpenAI function-calling format. `execute-tool-calls` routes the LLM's tool call requests to your registered handlers and returns results ready to send back. Tool results include `role`, `tool_call_id`, `content`, and `is_error`.

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

  * `examples/file-server.raku` — File system tools using tool groups

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

