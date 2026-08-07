use MCP::Server::Protocol;

#| Immutable per-request context: which protocol era a message belongs to, what
#| the client told us about itself, where notifications raised while the request
#| is in flight should go, and whether the caller has walked away.
#|
#| MCP::Server binds the live instance to the $*MCP-REQUEST-CONTEXT dynamic
#| variable around every dispatch, so handlers (and MCP::Server.log) can reach it
#| without a signature change, and every thread sees its own request's context.
#| Nothing here is mutable, so passing a context to a handler running on another
#| thread carries none of the usual shared-state hazards.
unit class MCP::Server::Context;

subset Era is export of Str where 'legacy' | 'modern';

has Era:D $.era = 'legacy';
has Str $.protocol-version;

#| Level the client opted into for this request (2026-07-28 _meta logLevel).
#| Undefined means request-scoped logging is switched off.
has Str $.log-level;

has %.client-info;
has %.client-capabilities;

#| Notification sink for this request.  Undefined means notifications are
#| dropped, which is what a bare handle-request with no transport has always
#| done.
has &.emit;

# Held privately so `cancelled` can answer the question handlers actually care
# about (has the caller given up?) instead of handing out the Promise itself.
has Promise $!cancelled;

submethod TWEAK(Promise :$cancelled) {
	$!cancelled = $cancelled;
}

#| Deliver a notification on this request's channel.  Returns True when it was
#| actually delivered and False when the context has no sink, which lets callers
#| fall back to a transport-wide channel if they have one.
method emit-notification(%notif --> Bool:D) {
	return False unless &!emit.defined;
	&!emit(%notif);
	True;
}

#| Should a log message at $level reach the client for this request?  The modern
#| era demands an explicit per-request opt-in — a 2026-07-28 server MUST NOT send
#| notifications/message for a request that omitted _meta logLevel — while the
#| legacy era leaves the decision to the server's own initialized/setLevel
#| gating and so always says yes here.
method wants-log(Str:D $level --> Bool:D) {
	return True if $!era eq 'legacy';
	return False unless $!log-level.defined;
	log-level-at-least($level, $!log-level);
}

#| True once the caller has abandoned the request (an HTTP client closing the
#| response stream, say).  A broken cancellation promise counts as cancelled: the
#| signal itself failed, so the safe reading is that nobody is listening.
#| Handlers may poll this; the server never interrupts a running handler.
method cancelled(--> Bool:D) {
	$!cancelled.defined && $!cancelled.status != Planned;
}
