use MCP::Server::Protocol;
use MCP::Server::Elicitation;

#| Immutable per-request context: which protocol era a message belongs to, what
#| the client told us about itself, where notifications raised while the request
#| is in flight should go, whether the caller wants to be kept posted on
#| progress, whether the caller has walked away — and how to ask the human on
#| the other end a question.
#|
#| MCP::Server binds the live instance to the $*MCP-REQUEST-CONTEXT dynamic
#| variable around every dispatch, so handlers (and MCP::Server.log) can reach it
#| without a signature change, and every thread sees its own request's context.
#| Nothing here is mutable, so passing a context to a handler running on another
#| thread carries none of the usual shared-state hazards.
unit class MCP::Server::Context;

subset Era is export of Str where 'legacy' | 'modern';

# What an elicitation form may ask for.  The 2026-07-28 schema allows a small,
# flat subset of JSON Schema in a requestedSchema -- primitives only, no nesting
# -- because the client has to render it as a form for a human.
my constant ELICIT-PROPERTY-TYPES = Set.new(<string number boolean>);
my constant ELICIT-PROPERTY-KEYS = Set.new(<type description enum>);

has Era:D $.era = 'legacy';
has Str $.protocol-version;

#| Level the client opted into for this request (2026-07-28 _meta logLevel).
#| Undefined means request-scoped logging is switched off.
has Str $.log-level;

has %.client-info;
has %.client-capabilities;

# The progress token the client attached to this request (_meta progressToken),
# undefined when it asked for no progress.  Held privately so `progress-token`
# can answer for whichever round of a multi round-trip call is in flight rather
# than for the request that first carried the call in.  Untyped: the protocol
# says string-or-number and calls it opaque, so it travels back out exactly as
# it came in.
has $!progress-token;

#| Notification sink for this request.  Undefined means this request has no
#| channel of its own, which is what a bare handle-request with no transport has
#| always had; C<MCP::Server.notify> then falls back to whatever the server has
#| (an C<:on-notify> sink, a legacy transport), and drops the notification when
#| it has nothing either.
has &.emit;

#| The elicitation rendezvous for this call, when the dispatcher parked it for
#| multi round-trip use; undefined otherwise.  Untyped on purpose: nothing here
#| needs to know it is an C<MCP::Server::Elicitation::Broker> rather than a test
#| double that quacks like one.
#|
#| When it is bound it also takes over notification, log-level and cancellation
#| decisions, because those belong to whichever round of the trip is currently
#| in flight rather than to the request that first carried the call in.
has $.broker;

#| Fallback used by C<elicit> when there is no MCP client to ask: an
#| C<:on-elicit> callback configured on the server.  Takes an ElicitRequest,
#| returns an ElicitResult.  See C<MCP::Server>'s C<:&on-elicit>.
has &.local-elicit;

# Held privately so `cancelled` can answer the question handlers actually care
# about (has the caller given up?) instead of handing out the Promise itself.
has Promise $!cancelled;

submethod TWEAK(Promise :$cancelled, :$progress-token) {
	$!cancelled = $cancelled;
	$!progress-token = $progress-token;
}

#| Deliver a notification on this request's channel.  Returns True when it was
#| actually delivered and False when the context has no sink, which lets callers
#| fall back to a transport-wide channel if they have one.
method emit-notification(%notif --> Bool:D) {
	# A parked call's notifications belong to the round in flight, not to the
	# request that started the trip -- that one has already been answered and
	# its sink is closed.
	with $!broker { return .emit-notification(%notif) }

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
	# Each round of a multi round-trip call opts in (or does not) for itself.
	with $!broker { return .wants-log($level) }

	return True if $!era eq 'legacy';
	return False unless $!log-level.defined;
	log-level-at-least($level, $!log-level);
}

#| The opaque token the client attached to this request when it asked to be kept
#| posted (C<_meta> C<progressToken>), or an undefined value when it did not.
#| A string or a number, whichever the client sent.
#|
#| Handlers normally want L<#method progress> rather than this; it is public
#| because "did anybody ask for progress?" is a question a handler may want to
#| answer before doing the work of computing it.
method progress-token() {
	# Each round of a multi round-trip call carries (or omits) its own token, and
	# the round in flight is the one whose channel a notification would go out
	# on -- so it is the one whose token has to be quoted back.
	with $!broker { return .progress-token }

	$!progress-token;
}

#| Tell the client how far along this request is, and say whether it was
#| actually sent.
#|
#|   my @files = find-them();
#|   for @files.kv -> $i, $file {
#|       process($file);
#|       $*MCP-REQUEST-CONTEXT.progress($i + 1, total => @files.elems, message => $file);
#|   }
#|
#| False, and nothing sent, when the client attached no C<progressToken> to the
#| request: progress is opt-in, a server MUST NOT send it unasked, and there
#| would be nothing to correlate the notification with. False as well when the
#| request has no notification channel at all (a bare C<handle-request>, or a
#| call parked mid-elicitation with no round in flight), which is the same
#| answer C<MCP::Server.notify> gives in that situation.
#|
#| Routing is the request's own channel, so a C<notifications/progress> raised
#| here can never surface in another request's stream. Nothing is gated on a
#| level — progress has none — and nothing is echoed to C<$*ERR>. Unlike
#| C<MCP::Server.notify> there is no legacy "has the client said it is
#| initialized?" gate either, because the question does not arise: a token can
#| only have come off a request the client sent, and a client sending requests
#| is a client that is listening.
#|
#| C<$progress> should increase on every call, C<:$total> is the count it is
#| working towards when that is known, and C<:$message> is a line a UI can show.
#| Both extras are omitted from the notification when they are not given, since
#| C<ProgressNotificationParams> marks them optional and an absent total is not
#| the same claim as a total of zero.
method progress(Real:D $progress, Real :$total, Str :$message --> Bool:D) {
	my $token = self.progress-token;
	return False without $token;

	self.emit-notification(notification('notifications/progress', {
		progressToken => $token,
		progress      => $progress,
		|($total.defined   ?? (total => $total)     !! ()),
		|($message.defined ?? (message => $message) !! ()),
	}));
}

#| True once the caller has abandoned the request (an HTTP client closing the
#| response stream, say).  A broken cancellation promise counts as cancelled: the
#| signal itself failed, so the safe reading is that nobody is listening.
#| Handlers may poll this; the server never interrupts a running handler.
method cancelled(--> Bool:D) {
	# While a call is parked for elicitation the question "has the caller given
	# up?" is about the round in flight, and about whether the call has been
	# abandoned outright -- never about the request that first carried it in,
	# whose disconnection is expected the moment it is answered.
	with $!broker { return .cancelled }

	$!cancelled.defined && $!cancelled.status != Planned;
}

#| A copy of this context with an elicitation broker bound to it.  Contexts are
#| immutable, so the dispatcher builds the handler's one rather than mutating
#| the request's.
method with-broker($broker --> MCP::Server::Context:D) {
	self.WHAT.new(
		era => $!era,
		protocol-version => $!protocol-version,
		log-level => $!log-level,
		client-info => %!client-info,
		client-capabilities => %!client-capabilities,
		emit => &!emit,
		local-elicit => &!local-elicit,
		progress-token => $!progress-token,
		:$broker,
		|($!cancelled.defined ?? (cancelled => $!cancelled) !! ()),
	);
}

#| Whether C<elicit> has anywhere to go: a client that declared the capability
#| and is waiting on a multi round-trip call, or a locally configured
#| C<:on-elicit> callback.  Handlers that can work either way should ask this
#| first rather than catching the exception C<elicit> throws.
method can-elicit(--> Bool:D) {
	$!broker.defined || &!local-elicit.defined;
}

#| Ask the human on the other end of the client a question, and block until
#| they answer.
#|
#|   my $answer = $*MCP-REQUEST-CONTEXT.elicit(
#|       'Which environment should I deploy to?',
#|       properties => {
#|           env => {
#|               type => 'string',
#|               description => 'Target environment',
#|               enum => <staging production>.List,
#|           },
#|           confirm => { type => 'boolean', description => 'Really deploy?' },
#|       },
#|       required => ['env',],
#|   );
#|
#|   return 'Deployment cancelled.' unless $answer.accepted;
#|   deploy($answer.content<env>);
#|
#| Property specs take C<type> (C<string>, C<number> or C<boolean>; C<string> if
#| omitted), an optional C<description> and an optional C<enum> of non-empty
#| strings.  Anything else is a mistake in the handler and dies rather than
#| being sent to a client that would not know what to do with it.  Pass
#| C<:%schema> instead to supply a whole C<requestedSchema> yourself, in which
#| case it travels verbatim and validating it is your business.
#|
#| C<:$timeout> (seconds) bounds the wait: when it runs out the question is
#| withdrawn and the answer is a C<cancel>.  Without one, the wait is bounded
#| only by the server's elicitation TTL, after which the call is abandoned and
#| this method throws.
#|
#| Throws when there is nowhere to ask — a legacy client, a modern client that
#| declared no elicitation capability, or the LLM bridge with no C<:on-elicit>
#| configured.  The message says which, and for a tool handler the framework
#| turns it into an C<isError> result, which is the right answer: the model
#| asked for something this deployment cannot do.
method elicit(
	Str:D $message, :%properties, :@required, :%schema, Real :$timeout
	--> MCP::Server::Elicitation::Outcome:D
) {
	my %request =
		method => 'elicitation/create',
		params => {
			# 'form' is the only mode this server offers: 'url' hands the user
			# off to a browser flow, which a library cannot invent for its host.
			mode => 'form',
			message => $message,
			requestedSchema => self!requested-schema(%properties, @required, %schema),
		};

	with $!broker {
		return self!outcome-from(
			.ask(%request, |($timeout.defined ?? (:$timeout) !! ())),
		);
	}

	with &!local-elicit {
		return self!outcome-from($_(%request));
	}

	die self!no-elicitation-path;
}

# Why this context cannot ask anybody anything, said in terms of what the
# server author can actually do about it.
method !no-elicitation-path(--> Str:D) {
	return 'Cannot elicit: elicitation needs a 2026-07-28 client '
		~ '(or pass :on-elicit to MCP::Server)'
		if $!era eq 'legacy';

	my $declared = %!client-capabilities<elicitation>;
	return 'Cannot elicit: this client did not declare the elicitation '
		~ 'capability, so the server must not ask'
		unless $declared ~~ Associative && ($declared<form>:exists);

	'Cannot elicit: no elicitation path here: the LLM bridge has no MCP client '
		~ 'to ask; pass :on-elicit to MCP::Server';
}

# An ElicitResult off the wire (or out of a local callback) is whatever the
# other side chose to send.  Anything that is not an answer is a refusal.
method !outcome-from($result --> MCP::Server::Elicitation::Outcome:D) {
	my %raw = $result ~~ Associative ?? $result.Hash !! {};
	my $action = %raw<action>;
	$action = 'decline'
		unless $action ~~ Str:D && ($action eq 'accept' | 'decline' | 'cancel');

	my %content = ($action eq 'accept' && %raw<content> ~~ Associative)
		?? %raw<content>.Hash !! {};

	MCP::Server::Elicitation::Outcome.new(:$action, :%content);
}

# The requestedSchema an ElicitRequest carries: either the caller's own, or one
# built from the property specs, validated here so a malformed question fails in
# the handler that wrote it rather than in the client that received it.
method !requested-schema(%properties, @required, %schema --> Hash) {
	return %schema.Hash if %schema.defined && %schema.elems > 0;

	die 'Cannot elicit: pass at least one property (or a whole :%schema); a '
		~ 'question with no fields is one the user cannot answer'
		unless %properties.defined && %properties.elems > 0;

	my %props;
	for %properties.kv -> $name, $spec {
		die "Cannot elicit: property names must be non-empty strings, got '$name'"
			unless $name ~~ Str:D && $name.chars > 0;
		die "Cannot elicit: the spec for property '$name' must be an object, got a {$spec.^name}"
			unless $spec ~~ Associative;

		my %spec = $spec.Hash;
		if %spec.keys.grep({ $_ !(elem) ELICIT-PROPERTY-KEYS }).sort -> @unknown {
			die "Cannot elicit: unknown key(s) in the spec for property '$name': "
				~ "{@unknown.join(', ')}. Valid keys: {ELICIT-PROPERTY-KEYS.keys.sort.join(', ')}";
		}

		my $type = %spec<type> // 'string';
		die "Cannot elicit: property '$name' has type '{$type // ''}'; "
			~ "elicitation forms take string, number or boolean"
			unless $type ~~ Str:D && ELICIT-PROPERTY-TYPES{$type};

		my %prop = type => $type;

		with %spec<description> {
			die "Cannot elicit: the description of property '$name' must be a string"
				unless $_ ~~ Str:D;
			%prop<description> = $_;
		}

		with %spec<enum> {
			die "Cannot elicit: the enum of property '$name' must be a non-empty "
				~ 'list of non-empty strings'
				unless $_ ~~ Positional && .list.elems > 0
					&& .list.all ~~ Str:D && .list.all.chars > 0;
			die "Cannot elicit: property '$name' has an enum, so its type must be string"
				unless $type eq 'string';
			%prop<enum> = .list.Array;
		}

		%props{$name} = %prop;
	}

	my @want = @required.grep(*.defined).map(*.Str);
	if @want.grep({ %props{$_}:!exists }).sort -> @missing {
		die "Cannot elicit: required propert{@missing.elems == 1 ?? 'y' !! 'ies'} "
			~ "{@missing.join(', ')} {@missing.elems == 1 ?? 'is' !! 'are'} not declared";
	}

	my %out = type => 'object', properties => %props;
	%out<required> = @want.Array if @want.elems > 0;
	%out;
}
