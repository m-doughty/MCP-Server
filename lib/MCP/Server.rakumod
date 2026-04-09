use JSON::Fast;
use MCP::Server::Protocol;
use MCP::Server::Tool;
use MCP::Server::Resource;
use MCP::Server::Prompt;

use MCP::Server::Transport;
use MCP::Server::Transport::Stdio;

class ToolGroup {
	has $.server is required;
	has Str:D $.prefix is required;

	method tool(Str:D $name, Str :$description, :%params, :&handler!) {
		$!server.tool: "{$!prefix}/{$name}", :$description, :%params, :&handler;
	}
}

class MCP::Server is export {

has Str:D $.name is required;
has Str:D $.version = '1.0.0';
has Str $.instructions;
has MCP::Server::Tool %!tools;
has MCP::Server::Resource %!resources;
has MCP::Server::Prompt %!prompts;
has MCP::Server::Transport $!transport;
has Bool:D $!initialized = False;

# === Registration API ===

method tool(Str:D $name, Str :$description, :%params, :&handler!) {
	%!tools{$name} = MCP::Server::Tool.new(:$name, :$description, :%params, :&handler);
}

method tool-group(Str:D $prefix, &registrar) {
	my $group = ToolGroup.new(:server(self), :$prefix);
	registrar($group);
}

method resource(Str:D $uri, Str:D :$name!, Str :$description, Str :$mime-type, :&handler!) {
	%!resources{$uri} = MCP::Server::Resource.new(:$uri, :$name, :$description, :$mime-type, :&handler);
}

method prompt(Str:D $name, Str :$description, :@arguments, :&handler!) {
	%!prompts{$name} = MCP::Server::Prompt.new(:$name, :$description, :@arguments, :&handler);
}

# === LLM tool bridge ===

method tools-for-llm(--> List) {
	%!tools.values.map(-> $tool {
		{
			type => 'function',
			function => {
				name => $tool.name,
				|($tool.description.defined ?? (description => $tool.description) !! ()),
				parameters => $tool.input-schema,
			},
		}
	}).list;
}

method execute-tool-calls(@tool-calls --> List) {
	@tool-calls.map(-> %tc {
		my $fn-name = %tc<function><name>;
		my $args-json = %tc<function><arguments> // '{}';
		my $call-id = %tc<id> // '';

		my %arguments;
		try {
			%arguments = from-json($args-json);
			CATCH { default { } }
		}

		my $result;
		my $is-error = False;
		if %!tools{$fn-name}:exists {
			try {
				$result = %!tools{$fn-name}.call(%arguments);
				CATCH {
					default {
						$result = .message;
						$is-error = True;
					}
				}
			}
		} else {
			$result = "Unknown tool: '$fn-name'";
			$is-error = True;
		}

		{
			role => 'tool',
			tool_call_id => $call-id,
			content => ~($result // ''),
		};
	}).list;
}

# === Run loop ===

method run(MCP::Server::Transport :$transport) {
	$!transport = $transport // MCP::Server::Transport::Stdio.new;
	self.log('info', "Starting MCP server: $!name v$!version");

	loop {
		my $line = $!transport.read-message;
		last unless $line.defined;
		last if $line.trim eq '';

		my %msg = parse-message($line);

		# If parse-message returned an error response directly
		if %msg<error>:exists {
			$!transport.write-message(format-message(%msg));
			next;
		}

		# Notifications have no id — don't send a response
		if !(%msg<id>:exists) {
			self!handle-notification(%msg);
			next;
		}

		my %response = self.handle-request(%msg);
		$!transport.write-message(format-message(%response));
	}

	self.log('info', 'MCP server shutting down');
}

# === Request dispatch (public for testing) ===

method handle-request(%msg --> Hash) {
	my $id = %msg<id>;
	my $method = %msg<method>;
	my %params = %msg<params> // {};

	given $method {
		when 'initialize'         { self!handle-initialize($id, %params) }
		when 'ping'               { success-response($id, {}) }
		when 'tools/list'         { self!handle-tools-list($id, %params) }
		when 'tools/call'         { self!handle-tools-call($id, %params) }
		when 'resources/list'     { self!handle-resources-list($id, %params) }
		when 'resources/read'     { self!handle-resources-read($id, %params) }
		when 'prompts/list'       { self!handle-prompts-list($id, %params) }
		when 'prompts/get'        { self!handle-prompts-get($id, %params) }
		default                   { error-response($id, METHOD_NOT_FOUND, "Method not found: $method") }
	}
}

# === Logging ===

method log(Str:D $level, Str:D $message) {
	$*ERR.say("[MCP/$level] $message");
	if $!transport.defined && $!initialized {
		my %notif = notification('notifications/message', {
			level => $level, logger => $!name, message => $message,
		});
		$!transport.write-message(format-message(%notif));
	}
}

# === Internal handlers ===

method !handle-notification(%msg) {
	given %msg<method> {
		when 'notifications/initialized' {
			$!initialized = True;
			self.log('info', 'Client initialized');
		}
		when 'notifications/cancelled' {
			# Acknowledge but no action needed for sync server
		}
	}
}

method !handle-initialize($id, %params --> Hash) {
	my %capabilities;
	%capabilities<tools> = {} if %!tools.elems > 0;
	%capabilities<resources> = {} if %!resources.elems > 0;
	%capabilities<prompts> = {} if %!prompts.elems > 0;
	%capabilities<logging> = {};

	success-response($id, {
		protocolVersion => '2025-11-25',
		capabilities => %capabilities,
		serverInfo => {
			name => $!name,
			version => $!version,
		},
		|($!instructions.defined ?? (instructions => $!instructions) !! ()),
	});
}

method !handle-tools-list($id, %params --> Hash) {
	success-response($id, {
		tools => %!tools.values.map(*.to-hash).list,
	});
}

method !handle-tools-call($id, %params --> Hash) {
	my Str $name = %params<name> // '';
	unless %!tools{$name}:exists {
		return error-response($id, INVALID_PARAMS, "Unknown tool: '$name'");
	}

	my %arguments = %params<arguments> // {};
	my $tool = %!tools{$name};

	try {
		my $result = $tool.call(%arguments);
		if $result ~~ Str {
			return success-response($id, tool-result($result));
		} elsif $result ~~ List {
			return success-response($id, tool-result-from-content($result));
		} elsif $result ~~ Hash {
			return success-response($id, $result);
		}
		return success-response($id, tool-result(~$result));
		CATCH {
			default {
				return success-response($id, tool-result(.message, :is-error));
			}
		}
	}
}

method !handle-resources-list($id, %params --> Hash) {
	success-response($id, {
		resources => %!resources.values.map(*.to-hash).list,
	});
}

method !handle-resources-read($id, %params --> Hash) {
	my Str $uri = %params<uri> // '';
	unless %!resources{$uri}:exists {
		return error-response($id, INVALID_PARAMS, "Unknown resource: '$uri'");
	}

	try {
		my %result = %!resources{$uri}.read;
		return success-response($id, %result);
		CATCH {
			default {
				return error-response($id, INTERNAL_ERROR, .message);
			}
		}
	}
}

method !handle-prompts-list($id, %params --> Hash) {
	success-response($id, {
		prompts => %!prompts.values.map(*.to-hash).list,
	});
}

method !handle-prompts-get($id, %params --> Hash) {
	my Str $name = %params<name> // '';
	unless %!prompts{$name}:exists {
		return error-response($id, INVALID_PARAMS, "Unknown prompt: '$name'");
	}

	my %arguments = %params<arguments> // {};

	try {
		my %result = %!prompts{$name}.get(%arguments);
		return success-response($id, %result);
		CATCH {
			default {
				return error-response($id, INTERNAL_ERROR, .message);
			}
		}
	}
}
}
