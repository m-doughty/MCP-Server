#| Server-side elicitation: the machinery behind
#| C<$*MCP-REQUEST-CONTEXT.elicit>, which lets a tool, resource or prompt
#| handler stop in the middle of its work and ask the human on the far side of
#| the client a question.
#|
#| The 2026-07-28 protocol calls this pattern MRTR — multi round-trip requests.
#| A server that needs input answers the request it is serving with
#| C<resultType: "input_required">, a map of C<inputRequests> and an opaque
#| C<requestState>; the client asks its user, then sends the B<same> request
#| again with the answers and that state attached.  Nothing about that shape is
#| in this file: it is the dispatcher's (see C<MCP::Server>).  What is here is
#| the awkward part underneath it — how a handler that is halfway through a
#| computation survives the gap between the two requests.
#|
#| =head2 The continuation model
#|
#| The handler is B<parked>, not restarted.  It runs on a thread of its own and
#| blocks in C<await> inside L<#method ask>; C<await> inside a C<start> block
#| suspends the continuation rather than pinning a pool thread, so a parked call
#| costs a data structure and no thread at all.  Restarting the handler on the
#| retry instead would re-run every side effect it had already performed, which
#| for a tool that writes files is not a refinement but a bug.
#|
#| That makes C<requestState> a token naming an in-process rendezvous rather
#| than a serialised continuation.  The spec allows it — the state is opaque and
#| "servers MAY use any encoding" — at the cost that a parked call does not
#| survive a restart of the process, and that a load-balanced deployment must
#| pin the retry to the instance that asked.  Both are documented in
#| C<docs/Readme.rakudoc>.
#|
#| =head2 The three classes
#|
#| =item L<#class Outcome> — what a handler gets back: an action and, when the
#|       user accepted, the content they filled in.  A refusal is an answer, so
#|       C<decline> and C<cancel> arrive as ordinary return values and never as
#|       exceptions.
#| =item L<#class Broker> — one per parked call: the rendezvous between the
#|       handler thread (asking) and the dispatcher thread (carrying questions
#|       to the client and answers back).
#| =item L<#class Table> — token → parked call, with a TTL, a cap and
#|       single-use, method-pinned claiming.
unit module MCP::Server::Elicitation;

# The three actions an ElicitResult may carry (2026-07-28 schema.ts,
# ElicitResult.action).  Anything else on the wire is treated as a decline
# rather than as an error: a client that answers nonsense has still, in
# substance, refused.
my subset ElicitAction of Str where 'accept' | 'decline' | 'cancel';

#| One answer to one elicitation.
#|
#|   my $answer = $*MCP-REQUEST-CONTEXT.elicit('Which branch?', properties => {
#|       branch => { type => 'string', description => 'Branch to deploy' },
#|   }, required => ['branch',]);
#|
#|   return 'Nothing deployed.' unless $answer.accepted;
#|   deploy($answer.content<branch>);
#|
#| C<content> is only ever populated for an C<accept>; the other two actions
#| carry an empty hash, because a user who said no said nothing else.
class Outcome {
	#| C<'accept'>, C<'decline'> or C<'cancel'>.
	has ElicitAction:D $.action is required;

	#| The form the user filled in, keyed by property name.  Empty unless the
	#| action is C<accept>.
	has %.content;

	#| The user answered the question.
	method accepted(--> Bool:D) { $!action eq 'accept' }

	#| The user refused this particular question.  The call is expected to carry
	#| on and do something sensible without the answer.
	method declined(--> Bool:D) { $!action eq 'decline' }

	#| The user dismissed the whole interaction (or the wait timed out).  The
	#| polite reading is "stop asking me things".
	method cancelled(--> Bool:D) { $!action eq 'cancel' }
}

# One inputResponses value, reduced to something a handler can act on.  A
# non-object, or an object naming an action the protocol does not have, is a
# decline: the user did not answer, and treating it as anything else would
# either invent consent or spin the loop.
my sub normalise-result($value --> Hash) {
	return { action => 'decline' } unless $value ~~ Associative;
	my %raw = $value.Hash;
	return { action => 'decline' } unless %raw<action> ~~ ElicitAction;

	my %out = action => %raw<action>.Str;
	%out<content> = %raw<content>.Hash
		if %out<action> eq 'accept' && %raw<content> ~~ Associative;
	%out;
}

#| The rendezvous for one parked call.  Created by the dispatcher when an
#| MRTR-eligible request arrives from a client that declared the elicitation
#| capability, and thrown away when the call finally answers.
#|
#| Two threads meet here and only here:
#|
#| =item the B<handler> thread, inside L<#method ask>, which registers a
#|       question and blocks until it is answered, withdrawn or abandoned;
#| =item the B<dispatcher> thread, which waits on L<#method round-ready>, takes
#|       the outstanding questions with L<#method take-requests>, sends them to
#|       the client, and on the retry hands the answers back through
#|       L<#method deliver>.
#|
#| Everything is done under one lock and every wakeup is a C<Promise>, so a
#| question answered between the two threads' turns can never be lost: the
#| answer is already in the promise the handler is waiting on.
#|
#| =head2 Rounds and the request context
#|
#| Each round of the trip is a B<different> JSON-RPC request, with its own
#| notification sink and its own cancellation signal.  The broker is told which
#| context is live with L<#method begin-round> / L<#method end-round>, and
#| C<MCP::Server::Context> delegates C<emit-notification>, C<wants-log>,
#| C<progress-token> and C<cancelled> to it, so a log line raised by the handler
#| in round three goes out on round three's channel.  While the call is parked
#| there is no live context at all: emissions are dropped, there is no progress
#| token to quote and C<cancelled> is False, because the
#| request that carried the call in has already been answered and its
#| disconnection is expected rather than a signal to give up.
class Broker {
	#| The method this call is serving.  Pinned so a retry cannot resume a
	#| C<tools/call> continuation through C<resources/read>.
	has Str:D $.method is required;

	has Lock $!lock .= new;

	# key => { request => %elicit-request, promise => Promise, vow => Vow }
	has %!pending;
	has Int:D $!next-key = 0;

	# Kept while at least one question is waiting to be carried to the client.
	# Renewed by take-requests, and re-kept by anything that leaves a question
	# outstanding -- including a round that answered nothing.
	has Promise $!round-ready = Promise.new;

	# The context of the round currently in flight, undefined while parked.
	has $!round-ctx;

	# Kept once this call has been given up on; every pending answer is broken
	# with the reason at the same moment.
	has Promise $.abandoned = Promise.new;
	has Str $!abandon-reason;

	has Bool:D $!closed = False;

	#| Ask the client one question and block until it answers.  Takes an
	#| ElicitRequest (C<< { method => 'elicitation/create', params => {...} } >>)
	#| and returns the bare ElicitResult the client sent back.
	#|
	#| Three things can end the wait:
	#|
	#| =item an B<answer>, which is returned as-is;
	#| =item B<abandonment> (TTL expiry, capacity refusal, shutdown), which
	#|       throws — the handler is not going to get an answer and pretending
	#|       otherwise would have it act on a fiction;
	#| =item the optional B<timeout>, which withdraws the question and returns a
	#|       C<cancel>, because "nobody answered in time" is a refusal and not a
	#|       malfunction.
	method ask(%request, Real :$timeout --> Hash) {
		my Str $key;
		my Promise $answer;

		$!lock.protect: {
			die "This elicitation broker is closed and cannot take new questions"
				if $!closed;
			$key = 'q' ~ ++$!next-key;
			$answer = Promise.new;
			%!pending{$key} = {
				request => %request.Hash,
				promise => $answer,
				vow     => $answer.vow,
			};
			self!refresh-round-ready;
		}

		my @waits = $answer, $!abandoned;
		@waits.push(Promise.in($timeout)) if $timeout.defined && $timeout > 0;
		await Promise.anyof(|@waits);

		# The answer wins even in a photo finish with the timeout: it is the
		# thing the user actually did.  await rather than .result so an
		# abandonment breaks out through the exception the vow carries.
		return await $answer unless $answer.status === Planned;

		if $!abandoned.status === Kept {
			# Withdraw as well as throw: a question registered in the moment
			# between abandon() clearing the table and this thread noticing
			# would otherwise sit there forever with nobody behind it.
			my $why = $!lock.protect: {
				%!pending{$key}:delete;
				$!abandon-reason // 'the request was abandoned';
			};
			die "Elicitation abandoned: $why";
		}

		# Timed out.  Withdraw the question so the next round does not ask it
		# again on behalf of a handler that has stopped listening.
		$!lock.protect: {
			%!pending{$key}:delete;
			self!refresh-round-ready;
		}
		{ action => 'cancel' };
	}

	#| A promise kept while there is a question the client has not been shown
	#| yet.  The dispatcher waits on this and on the handler's own promise: one
	#| of the two always settles.
	method round-ready(--> Promise:D) {
		$!lock.protect: {
			self!refresh-round-ready;
			$!round-ready;
		}
	}

	# Caller holds the lock.  Keeping a Promise under it is safe: nothing this
	# class subscribes to takes the lock, and a Promise's continuations are cued
	# on the scheduler rather than run inline.
	method !refresh-round-ready(--> Nil) {
		$!round-ready.keep(True)
			if %!pending.elems > 0 && $!round-ready.status === Planned;
	}

	#| Every question that has not been answered yet, as the C<inputRequests>
	#| map the client is owed: server-assigned keys, ElicitRequest values.
	#|
	#| Renews C<round-ready> before returning, so a question the handler asks
	#| between this snapshot and the next round still wakes the dispatcher.
	#| Questions are B<not> removed: an unanswered one is asked again next
	#| round, which is what the spec tells a server to do with a key the client
	#| left out.
	method take-requests(--> Hash) {
		$!lock.protect: {
			$!round-ready = Promise.new;
			my %requests;
			for %!pending.kv -> $key, $entry {
				%requests{$key} = $entry<request>.Hash;
			}
			%requests;
		}
	}

	#| Hand one round's C<inputResponses> map back to the handlers waiting on
	#| it.  Every departure from the expected shape has an answer rather than an
	#| error, because the alternative is a call that spins:
	#|
	#| =item a value that is not an ElicitResult, or names an action nobody has
	#|       heard of, is delivered as a B<decline> — it converges;
	#| =item a key naming no outstanding question is B<warned about and
	#|       ignored> — answering a question we never asked would corrupt
	#|       another one;
	#| =item a question the client left out B<stays pending> and is asked again
	#|       next round, per the spec's "the server SHOULD ask again".
	method deliver(%responses, :&warn --> Nil) {
		my @settle;
		my Str @unknown;

		$!lock.protect: {
			for %responses.kv -> $key, $value {
				unless %!pending{$key}:exists {
					@unknown.push($key);
					next;
				}
				my $entry = %!pending{$key}:delete;
				@settle.push($entry<vow> => normalise-result($value));
			}
			self!refresh-round-ready;
		}

		# Outside the lock: keeping a vow wakes a handler thread, and &warn is
		# the caller's code, which may do anything at all including log.
		for @settle -> $pair {
			$pair.key.keep($pair.value);
		}
		if &warn {
			&warn(
				"elicitation answer for '$_' does not match any outstanding "
					~ "question on this $!method call; ignoring it"
			) for @unknown;
		}
	}

	#| Point the broker's notification and cancellation delegation at the
	#| context of the round now in flight.
	method begin-round($ctx --> Nil) {
		$!lock.protect: { $!round-ctx = $ctx };
	}

	#| Forget the round's context: the call is about to be parked, and the
	#| request that carried it in is about to be answered.
	method end-round(--> Nil) {
		$!lock.protect: { $!round-ctx = Any };
	}

	#| Give up on this call: nobody is coming back with answers.  Every pending
	#| question is broken with C<$reason>, so the handlers unwind through their
	#| own error paths (an C<isError> tool result, normally) rather than
	#| blocking forever.
	method abandon(Str:D $reason --> Nil) {
		my @vows;
		$!lock.protect: {
			$!abandon-reason //= $reason;
			@vows = %!pending.values.map(*.<vow>);
			%!pending = ();
			$!abandoned.keep(True) if $!abandoned.status === Planned;
		}
		.break("Elicitation abandoned: $reason") for @vows;
	}

	#| The handler has finished, so no answer can ever be useful again.  Any
	#| question still outstanding — one asked from a thread the handler spawned
	#| and then walked away from — is broken rather than left to leak.
	method close(--> Nil) {
		my @vows;
		$!lock.protect: {
			$!closed = True;
			@vows = %!pending.values.map(*.<vow>);
			%!pending = ();
		}
		.break('Elicitation broker closed: the call it belonged to has finished')
			for @vows;
	}

	#| How many questions are waiting for an answer.  For tests and diagnostics.
	method pending(--> Int:D) {
		$!lock.protect: { %!pending.elems };
	}

	# === Delegation targets for MCP::Server::Context ===

	#| Deliver a notification on the channel of the round in flight.  False
	#| while parked: there is no request to hang it off.
	method emit-notification(%notif --> Bool:D) {
		my $ctx = $!lock.protect: { $!round-ctx };
		return False without $ctx;
		$ctx.emit-notification(%notif);
	}

	#| The progress token of the round in flight, or an undefined value when
	#| that round asked for no progress — and while the call is parked, when
	#| there is no round to attach a notification to at all.
	method progress-token() {
		my $ctx = $!lock.protect: { $!round-ctx };
		return Nil without $ctx;
		$ctx.progress-token;
	}

	#| Whether the round in flight opted in to logging at C<$level>.
	method wants-log(Str:D $level --> Bool:D) {
		my $ctx = $!lock.protect: { $!round-ctx };
		return False without $ctx;
		$ctx.wants-log($level);
	}

	#| Whether the handler should give up.  Abandonment counts; so does the
	#| current round's caller hanging up.  The B<original> request's
	#| cancellation deliberately does not: that request was answered with an
	#| C<input_required> result, and its stream closing afterwards is the normal
	#| course of events rather than a signal.
	method cancelled(--> Bool:D) {
		return True unless $!abandoned.status === Planned;
		my $ctx = $!lock.protect: { $!round-ctx };
		return False without $ctx;
		$ctx.cancelled;
	}
}

#| Every call parked waiting for its client to come back, keyed by the
#| C<requestState> token handed out with the C<input_required> result.
#|
#| The token is the only thing standing between a parked call and whoever
#| guesses at it, so claiming is defended four ways: it is B<single use> (a
#| claim removes the entry), B<method-pinned> (a C<tools/call> token cannot
#| resume through C<prompts/get>), B<TTL-bounded> (L<#has $.ttl> seconds, after
#| which the call is abandoned and its handler unwound) and B<capped>
#| (L<#has $.max-pending> parked calls at once, so a client that walks away from
#| every question cannot grow the table without limit).
#|
#| =head2 On the token itself
#|
#| It is a monotonic counter plus 128 bits from C<rand>.  Raku's core has no
#| CSPRNG, and C<rand> is a Mersenne Twister: an attacker who can see a few
#| tokens can in principle reconstruct its state and predict the next.  What
#| that buys them is the ability to answer somebody else's elicitation once,
#| within the TTL, on the right method — no data comes back out.  The
#| defence-in-depth above is what makes that acceptable for now; binding to a
#| real CSPRNG is a tracked follow-up rather than something this class pretends
#| to have.
class Table {
	#| Seconds a parked call waits for its client before it is abandoned.
	has Real:D $.ttl = 300;

	#| How many calls may be parked at once.
	has Int:D $.max-pending = 64;

	has Lock $!lock .= new;

	# token => { broker, work => Promise, method => Str, expires => Instant }
	has %!parked;
	has Int:D $!counter = 0;

	submethod TWEAK() {
		die "Elicitation ttl must be greater than zero seconds, got $!ttl"
			unless $!ttl > 0;
		die "Elicitation max-pending must be at least one, got $!max-pending"
			unless $!max-pending >= 1;
	}

	#| Park one call and return the token that resumes it, or an undefined
	#| C<Str> when the table is full — the caller is expected to abandon the
	#| broker and let the handler unwind rather than to queue.
	method park($broker, Promise:D $work, Str:D :$method --> Str) {
		# Reaping first means a table full of calls whose clients have gone is
		# not a table full at all.
		self.reap;

		my Str $token = $!lock.protect: {
			if %!parked.elems >= $!max-pending {
				Str;
			} else {
				my $minted = self!mint-token;
				%!parked{$minted} = {
					broker  => $broker,
					work    => $work,
					method  => $method,
					expires => now + $!ttl,
				};
				$minted;
			}
		};

		# The TTL backstop.  Cheap (one timer per parked call) and self-healing:
		# reap() is idempotent and a call that was claimed in the meantime is
		# simply not there any more.
		Promise.in($!ttl).then({ self.reap }) if $token.defined;

		$token;
	}

	#| Claim a parked call by token.  Returns the entry — C<broker>, C<work>,
	#| C<method> — or an empty hash when the token is unknown, already used,
	#| expired, or belongs to a different method.
	method claim(Str:D $token, Str:D :$method --> Hash) {
		self.reap;

		$!lock.protect: {
			my $entry = %!parked{$token};
			if $entry.defined && $entry<method> eq $method {
				%!parked{$token}:delete;
				$entry.Hash;
			} else {
				# A method mismatch leaves the entry alone: the token's rightful
				# owner may still be on its way, and this claim is either a
				# mistake or an attack.  Either way it gets nothing.
				{};
			}
		}
	}

	#| Abandon every parked call whose TTL has run out.  Called on every park
	#| and claim, and on a timer per parked call, so an idle server still lets
	#| go of its stragglers.
	method reap(--> Nil) {
		my @dead;
		$!lock.protect: {
			my $cutoff = now;
			# Collected first and deleted afterwards: deleting from a hash while
			# iterating its own .kv is not safe.
			for %!parked.kv -> $token, $entry {
				@dead.push($token => $entry) if $entry<expires> < $cutoff;
			}
			%!parked{.key}:delete for @dead;
		}

		for @dead -> $pair {
			$pair.value<broker>.abandon(
				'the client did not come back before the elicitation TTL expired'
			);
		}
	}

	#| How many calls are parked right now.  For tests, health endpoints and
	#| anybody wondering where their threads went.
	method pending(--> Int:D) {
		$!lock.protect: { %!parked.elems };
	}

	# Caller holds the lock.
	method !mint-token(--> Str:D) {
		my $serial = ++$!counter;
		# Four 32-bit draws rather than one big one: rand is a Num, so a single
		# draw against 2**128 would only ever carry a double's 53 bits.
		my $random = (^4).map({ (2 ** 32).rand.Int.fmt('%08x') }).join;
		"mrtr-{$serial}-{$random}";
	}
}
