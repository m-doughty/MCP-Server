use Cro::HTTP::Router;
use Cro::HTTP::Server;
use Cro::Transform;
use JSON::Fast;

use MCP::Server;
use MCP::Server::Protocol;
use MCP::Server::HTTP::Validation;

#| Streamable HTTP transport for MCP::Server, as defined by the 2026-07-28
#| protocol: one POST-only endpoint, no sessions, no server-initiated stream,
#| and every request self-describing through its C<_meta>.
#|
#|   my $server = MCP::Server.new(:name<demo>);
#|   $server.tool: 'greet', :handler(-> :%args { "Hi, %args<name>" });
#|   MCP::Server::HTTP.new(:$server, :port(8080)).run;
#|
#| The transport is modern-era only — C<initialize>, C<ping> and
#| C<logging/setLevel> answer METHOD_NOT_FOUND here — while the stdio transport
#| keeps serving both eras.  A request is answered either with a single JSON
#| object or, when the handler raises notifications and the client said it would
#| accept C<text/event-stream>, with an SSE stream scoped to that one request.
#|
#| It listens on 127.0.0.1 by default and speaks plain HTTP: put it behind a
#| reverse proxy for TLS, and use L<#method routes> to mount it inside a larger
#| Cro application when it needs authentication or other middleware.
unit class MCP::Server::HTTP;

#| The server whose catalogs and handlers this endpoint exposes.  Registration
#| must be finished before C<start>: the transport treats it as frozen and calls
#| it from many threads at once.
has MCP::Server:D $.server is required;

has Str:D $.host = '127.0.0.1';
has Int:D $.port = 8080;

#| Path the endpoint answers on, with or without surrounding slashes.  More than
#| one segment ('api/mcp') is fine.
has Str:D $.path = 'mcp';

#| Origins accepted in addition to the always-allowed loopback ones.  Entries are
#| exact strings or Regexes.
has @.allowed-origins;

#| Whether a request with no Origin header at all is accepted.  True by default:
#| non-browser MCP clients do not send one, and the header only exists to protect
#| browsers from DNS-rebinding attacks against a loopback server.
has Bool:D $.allow-no-origin = True;

#| Seconds between SSE keepalive comments, which stop proxies and clients from
#| timing out a stream whose handler is thinking.
has Real:D $.keepalive = 15;

# The running Cro::HTTP::Server, or an undefined value while stopped.
has $!service;

# $.path split for matching; the accessor keeps whatever the caller wrote.
has Str @!path-segments;

# Lowercased header name => the spelling used in diagnostics.
my constant %REQUIRED-HEADERS = Map.new(
	'mcp-protocol-version' => 'MCP-Protocol-Version',
	'mcp-method'           => 'Mcp-Method',
);

submethod TWEAK() {
	die "MCP HTTP port must be between 1 and 65535, got $!port"
		unless 1 <= $!port <= 65535;
	die "MCP HTTP keepalive must be greater than zero seconds, got $!keepalive"
		unless $!keepalive > 0;

	for @!allowed-origins -> $entry {
		die "Allowed origins must be strings or regexes, got a {$entry.^name}"
			unless ($entry ~~ Str:D) || ($entry ~~ Regex);
	}

	@!path-segments = $!path.split('/').grep(*.chars > 0);
}

#| Where this endpoint can be reached, for logs and error messages.
method endpoint(--> Str:D) {
	"http://{$!host}:{$!port}/{@!path-segments.join('/')}";
}

#| Start listening and return immediately.  Dies if this instance is already
#| running; use one instance per endpoint.
method start(--> Nil) {
	die "The MCP HTTP endpoint for '{$!server.name}' is already running"
		if $!service.defined;

	$!service = Cro::HTTP::Server.new(
		host => $!host, port => $!port, application => self.routes,
	);
	$!service.start;
	$!server.log('info', "MCP Streamable HTTP endpoint listening on {self.endpoint}");
}

#| Stop listening, letting in-flight responses finish.  Safe to call on a server
#| that was never started, so it works as a LEAVE/END handler.
method stop(--> Nil) {
	return unless $!service.defined;
	$!service.stop;
	$!service = Nil;
	$!server.log('info', 'MCP Streamable HTTP endpoint stopped');
}

#| Start listening and block until the process is asked to shut down, then stop
#| gracefully.  SIGINT always applies; SIGTERM is added when the platform has one
#| (Windows does not), which is a difference in what the OS can tell us rather
#| than a difference in what this transport supports.
method run(--> Nil) {
	self.start;
	LEAVE self.stop;

	my $shutdown = Promise.new;
	my $lock = Lock.new;

	my @signals = signal(SIGINT);
	with (try signal(SIGTERM)) { @signals.push($_) }

	my $tap = Supply.merge(@signals).tap: {
		$lock.protect: { $shutdown.keep(True) if $shutdown.status === Planned };
	};

	await $shutdown;
	$tap.close;
}

#| The endpoint as a Cro::Transform, for mounting inside a larger Cro
#| application:
#|
#|   route {
#|       before My::Auth::Middleware.new;
#|       include $mcp.routes;
#|   }
#|
#| This is the supported extension point for authentication: the routes only
#| match this endpoint's own path, so anything else in the surrounding route
#| block still gets a look at the request.
method routes(--> Cro::Transform) {
	# Bound, not copied, so the closures below see the normalised segments.
	my @want := @!path-segments;
	my &wanted-path = -> @segments { @segments.join('/') eq @want.join('/') };

	route {
		post -> *@segments where &wanted-path { self!handle-post }
		get -> *@segments where &wanted-path { self!method-not-allowed }
		delete -> *@segments where &wanted-path { self!method-not-allowed }
	}
}

# === Request pipeline ===

# Checks run cheapest-and-most-decisive first, so a request that has no business
# being here is turned away before its body is read, let alone dispatched.
method !handle-post(--> Nil) {
	CATCH {
		default {
			# Without this, Cro would answer with its own HTML error page; an MCP
			# client is owed JSON-RPC whatever went wrong.
			$!server.log('error', "Streamable HTTP request failed: {.message}");
			self!json-error(500, Any, INTERNAL_ERROR, 'Internal error');
		}
	}

	my $req = request;

	# 1. Origin.  This is the DNS-rebinding guard for a loopback server, so it
	# comes before anything that could have a side effect.
	my $origin = $req.header('Origin') // Str;
	unless origin-allowed($origin, allowed => @!allowed-origins, allow-no-origin => $!allow-no-origin) {
		self!json-error(403, Any, INVALID_REQUEST, "Origin not allowed: $origin");
		return;
	}

	# 2. Content type.  The endpoint speaks JSON-RPC and nothing else.
	my $content-type = $req.content-type;
	unless $content-type.defined && $content-type.type-and-subtype.lc eq 'application/json' {
		self!json-error(
			415, Any, INVALID_REQUEST,
			'Unsupported Media Type: the MCP endpoint accepts application/json',
		);
		return;
	}

	my %headers = self!header-map($req);

	# 3. The routing headers must be there.  They are what makes a modern request
	# inspectable by proxies without parsing the body, so a missing one is a
	# header mismatch rather than a plain bad request.
	for %REQUIRED-HEADERS.keys.sort -> $required {
		next if %headers{$required}:exists;
		self!json-error(
			400, Any, HEADER_MISMATCH,
			"Missing required {%REQUIRED-HEADERS{$required}} header",
		);
		return;
	}

	# 4. Version, from the header alone: HTTP is modern-only, so a legacy client
	# is turned away before its body is parsed.  The supported list names every
	# configured version, legacy included, so a client that guessed wrong can fall
	# back — the same list the core reports (see MCP::Server's version gate).
	my $header-version = %headers<mcp-protocol-version>;
	unless $!server.modern-protocol-versions.grep({ $_ eq $header-version }).elems > 0 {
		self!json(400, unsupported-protocol-version-error(
			Any, requested => $header-version, supported => $!server.protocol-versions,
		));
		return;
	}

	# 5. Body.
	my $body-text = self!request-text($req);
	unless $body-text.defined {
		self!json-error(400, Any, PARSE_ERROR, 'Parse error: request body is not valid UTF-8');
		return;
	}

	# JSON-RPC batching went away with the legacy era, and parse-message would
	# report an array as a parse error, which is the wrong diagnosis.
	if (try from-json($body-text)) ~~ Positional {
		self!json-error(
			400, Any, INVALID_REQUEST,
			'Invalid Request: batches are not supported; send one JSON-RPC message per request',
		);
		return;
	}

	my %msg = parse-message($body-text);
	if %msg<error>:exists {
		self!json(400, %msg);
		return;
	}

	# 6. Headers against body.
	with header-checks(%headers, %msg) -> %check {
		self!json-error(%check<status>, %msg<id>, %check<code>, %check<message>);
		return;
	}

	# 7. Dispatch.  A body with no id is a notification: JSON-RPC forbids a
	# response, so it is dispatched for its side effects and acknowledged.
	unless %msg<id>:exists {
		$!server.handle-modern-request(%msg);
		response.status = 202;
		return;
	}

	# A client that will not read an event stream gets a single JSON object, and
	# the request's notifications go no further than the server's own $*ERR.  The
	# spec leaves that choice to the server.
	my $accept = $req.header('Accept') // '';
	unless $accept.lc.contains('text/event-stream') {
		my %response = $!server.handle-modern-request(%msg);
		self!json(self!status-for(%response), %response);
		return;
	}

	self!stream-response(%msg);
}

#| SSE is decided lazily.  The handler runs while we wait for whichever comes
#| first: it finishing, or it saying something to the client.  A request that
#| answers without a word gets a plain JSON response, so only a request that
#| really has something to stream pays for a stream.
method !stream-response(%msg --> Nil) {
	my $lock = Lock.new;
	my @pending;
	my Bool $streaming = False;
	my $notifications = Supplier.new;
	my $first-notification = Promise.new;
	my $cancelled = Promise.new;

	my &notify = -> %notif {
		my Bool $live = $lock.protect: {
			if $streaming {
				True;
			} else {
				@pending.push(%notif);
				$first-notification.keep(True) if $first-notification.status === Planned;
				False;
			}
		};
		# Emitted outside the lock on purpose: the supply block takes the lock while
		# it drains the buffer, and emitting into a tapped Supplier runs the consumer
		# on this thread, so holding both would be a lock-ordering bug.
		$notifications.emit(%notif) if $live;
	};

	my $work = start { $!server.handle-modern-request(%msg, :&notify, :$cancelled) };
	await Promise.anyof($work, $first-notification);

	unless $lock.protect({ @pending.elems > 0 }) {
		# Nothing to stream, so the promise must be the thing that completed.
		# .result rethrows if the core itself blew up, which the route's CATCH
		# turns into a JSON-RPC 500.
		my %response = $work.result;
		self!json(self!status-for(%response), %response);
		return;
	}

	# Committed to streaming.  The status is 200 even if the response turns out to
	# be an error: an error is settled during dispatch, before any handler could
	# have raised a notification, so a stream that has started can only be
	# carrying a result.
	response.status = 200;
	header 'X-Accel-Buffering', 'no';
	header 'Cache-Control', 'no-store';

	content 'text/event-stream', supply {
		# Tap the live channel first and only then take the buffer, so a
		# notification raised in between lands in exactly one of the two.  The
		# response is whenever'd after the replay so it can never overtake it.
		whenever $notifications.Supply -> %notif {
			emit sse-event(%notif).encode('utf-8');
		}

		my @replay = $lock.protect: {
			$streaming = True;
			my @buffered = @pending;
			@pending = ();
			@buffered;
		};
		emit sse-event($_).encode('utf-8') for @replay;

		whenever $work -> %response {
			emit sse-event(%response).encode('utf-8');
			done;

			QUIT {
				default {
					$!server.log('error', "Streamable HTTP handler failed mid-stream: {.message}");
					emit sse-event(
						error-response(%msg<id>, INTERNAL_ERROR, 'Internal error')
					).encode('utf-8');
					done;
					True;
				}
			}
		}

		# Comments keep proxies and impatient clients from tearing down a stream
		# whose handler is still working.
		whenever Supply.interval($!keepalive, $!keepalive) {
			emit sse-comment().encode('utf-8');
		}

		# The client closing the stream is the only cancellation signal this
		# protocol has.  Handlers poll $*MCP-REQUEST-CONTEXT.cancelled; a
		# synchronous one that never looks simply runs to completion and its
		# result is discarded.  Firing on a normal `done` too is harmless: the
		# work is already finished by then.
		CLOSE {
			$cancelled.keep(True) if $cancelled.status === Planned;
			$notifications.done;
		}
	}
}

# === Helpers ===

#| Headers keyed by lowercased name, which is what
#| MCP::Server::HTTP::Validation expects.  Repeats are joined with commas, as
#| RFC 9110 says a client should have sent them in the first place — and as a
#| bonus a repeated routing header then fails the header checks instead of
#| letting the first copy win.
method !header-map($req --> Hash) {
	my %headers;
	for $req.headers -> $header {
		my $name = $header.name.lc;
		%headers{$name} = %headers{$name}:exists
			?? "{%headers{$name}},{$header.value}"
			!! $header.value;
	}
	%headers;
}

#| The request body as text, or an undefined Str when it is not valid UTF-8.
method !request-text($req --> Str) {
	my $blob = await $req.body-blob;
	my $text = try $blob.decode('utf-8');
	return Str unless $text.defined;
	$text;
}

#| METHOD_NOT_FOUND is the transport's 404: it covers unknown methods and
#| subscriptions/listen, which this server does not implement.  Everything else,
#| errors included, is a 200 carrying a JSON-RPC error object.
method !status-for(%response --> Int:D) {
	(%response<error><code> // 0) == METHOD_NOT_FOUND ?? 404 !! 200;
}

method !method-not-allowed(--> Nil) {
	header 'Allow', 'POST';
	self!json(405, error-response(
		Any, INVALID_REQUEST, 'Method Not Allowed: the MCP endpoint only accepts POST',
	));
}

method !json(Int:D $status, %body --> Nil) {
	response.status = $status;
	content 'application/json', %body;
}

method !json-error(Int:D $status, $id, Int:D $code, Str:D $message --> Nil) {
	self!json($status, error-response($id, $code, $message));
}
