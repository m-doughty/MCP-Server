use JSON::Fast;

#| The scheduler both LLM tool bridges run their batches through:
#| C<MCP::Server>'s (a local toolkit) and C<MCP::Client>'s (a server over the
#| wire).  It lives here, in one place, because the two bridges are required to
#| be interchangeable — the same toolkit reached locally and reached over MCP
#| must answer the same way — and "how a batch is executed" is exactly the sort
#| of decision that drifts when it is written twice.
#|
#| B<What it decides.>  A batch is run strictly serially, in the caller's order,
#| unless B<every> call in it is annotated read-only I<and> idempotent (see
#| L<#sub concurrency-safe>), in which case the distinct calls run on up to
#| C<:$concurrency> workers and the answers are reassembled in slot order.
#| Nothing is ever raced over, hypered, or returned lazily: the results are a
#| real List, in the caller's order, and by the time this returns every unit of
#| work has finished.
#|
#| B<Why "every".>  One mutating call in a batch makes the whole batch a
#| sequence: an C<fs_read> beside an C<fs_write> may be reading what that write
#| just wrote, and a model that asked for both in one turn is describing an
#| order.  The annotation is the only evidence there is that a call cannot be
#| part of such a sequence, so a batch is only ever widened when every one of
#| its calls carries it.
unit module MCP::Server::Batch;

#| Whether an MCP tool's C<annotations> say a call of it may run beside another
#| one: C<readOnlyHint> B<and> C<idempotentHint>, both explicitly true.
#|
#| Read-only alone is not enough.  C<readOnlyHint> is a promise about the
#| I<world> ("this changes nothing"), and C<idempotentHint> is a promise about
#| I<repetition> ("calling it again with the same arguments adds nothing") —
#| and the second is what makes de-duplication inside a batch honest.  A tool
#| that reads but is not idempotent (one that asks a human a question, say, or
#| hands out a fresh handle) is read-only and still hostile to being run twice
#| at once, so it fails this test and keeps its place in the queue.
#|
#| Anything that is not an explicit C<True> is a no: an absent hint, an
#| undefined one, a string C<"true"> from a server that hand-rolled its JSON.
#| Concurrency is opted into, never inferred.
sub concurrency-safe($annotations --> Bool:D) is export {
	return False unless $annotations ~~ Associative;
	my %a = $annotations.Hash;
	(%a<readOnlyHint> ~~ Bool:D && %a<readOnlyHint>)
		&& (%a<idempotentHint> ~~ Bool:D && %a<idempotentHint>);
}

#| The identity two calls have to share to be de-duplicated: the tool's name
#| and its arguments, canonicalised.  C<:sorted-keys> is what makes it an
#| identity rather than a spelling — C<< {a => 1, b => 2} >> and
#| C<< {b => 2, a => 1} >> are the same call — while array order is preserved,
#| because C<[1, 2]> is not C<[2, 1]>.
#|
#| The NUL is a separator no tool name may contain (MCP names are
#| C<[A-Za-z0-9_-]>), so no name-plus-arguments pair can collide with another
#| by straddling it.
#|
#| Arguments that cannot be rendered (a handler-built value with no JSON form)
#| yield an undefined C<Str>, which every caller reads as "never de-duplicate
#| this one" — the safe direction.
sub argument-identity(Str:D $name, %arguments --> Str) is export {
	my $json = try to-json(%arguments, :!pretty, :sorted-keys);
	return Str without $json;
	$name ~ "\0" ~ $json;
}

#|( Run one batch of tool calls and return one answer per slot, in slot order.

    Each slot is a Hash:

    =item C<id> — the model's C<tool_call_id> for this slot.  Used only to
          re-stamp a de-duplicated answer, which is what keeps every result
          filed under the id of the call it answers.
    =item C<concurrent> — whether this call may run beside its neighbours.
          One C<False> makes the whole batch serial.
    =item C<key> — the de-duplication identity from L<#sub argument-identity>,
          or an undefined C<Str> for a slot that must always run on its own.
    =item C<work> — the thunk that produces the answer.  Called exactly once
          per distinct key in a concurrent batch, once per slot in a serial
          one, and B<on whatever thread the scheduler picked>.

    B<De-duplication, and what it saves.>  Two identical calls in one
    concurrent batch — the same tool, the same arguments — execute B<once>, and
    the answer is copied into both slots with each slot's own C<tool_call_id>.
    A model that asks to read one file twice in a turn pays for one read: one
    file opened, one page fetched, one lot of tokens back through the counter.
    It is confined to concurrent batches on purpose: the annotation is the
    evidence that the second call could not have seen anything different, and
    without it "the model asked twice" has to mean twice.

    B<Bounded, not unbounded.>  At most C<:$concurrency> thunks are in flight
    however wide the batch is: fifty annotated reads are four workers pulling
    from a queue, not fifty threads.  Every worker is shielded, so a thunk that
    throws — which neither bridge's does, both being total by contract —
    becomes an error result for its slot instead of taking the batch down with
    it. )
sub run-tool-batch(@slots, Int:D :$concurrency = 4 --> List:D) is export {
	# Nothing to schedule, or nothing to gain: one slot is its own order, and a
	# width of one is the serial loop spelled expensively.
	my Bool:D $wide = $concurrency > 1 && @slots.elems > 1
		&& !@slots.first({ !(($_<concurrent> // False)) }).defined;

	unless $wide {
		# Eager and in order, deliberately: tools have side effects, and they
		# happen here, inside the call that asked for them.
		my @serial;
		@serial.push(run-slot($_)) for @slots;
		return @serial.List;
	}

	# Slot index => the index of the slot whose thunk answers for it.  A slot
	# is its own leader unless an earlier slot has the same key.
	my Int @leader-of = ^@slots.elems;
	my Int %leader{Str};
	for @slots.kv -> Int $index, %slot {
		my $key = %slot<key>;
		next unless $key ~~ Str:D;
		if %leader{$key}:exists {
			@leader-of[$index] = %leader{$key};
		}
		else {
			%leader{$key} = $index;
		}
	}

	my Int @work = (^@slots.elems).grep({ @leader-of[$_] == $_ });

	# Pre-sized, and that is load-bearing: workers assign into it from several
	# threads at once, and an Array that has to GROW to take an element is not
	# safe to do that to.  Every slot it will ever hold exists before the first
	# worker starts, so each assignment only ever replaces the value in a
	# container that is already there.
	my @answers = Any xx @slots.elems;

	my Lock $queue-lock .= new;
	my Int $next = 0;

	# A fixed pool pulling from a shared cursor, rather than one Promise per
	# call with a semaphore in front of it: the bound is then structural (there
	# are only ever N workers) instead of a thing every unit of work has to
	# remember to respect.
	my @workers = (^min($concurrency, @work.elems)).map({
		start {
			loop {
				my $at = $queue-lock.protect: {
					$next < @work.elems ?? $next++ !! Int;
				};
				last without $at;
				my Int $index = @work[$at];
				@answers[$index] = run-slot(@slots[$index]);
			}
		}
	});

	# `await`, not `race`/`hyper`: the answers are already indexed, and what
	# this waits for is every worker having finished writing.
	await @workers;

	@slots.kv.map(-> Int $index, %slot {
		my Int:D $leader = @leader-of[$index];
		$leader == $index
			?? @answers[$index]
			!! restamp(@answers[$leader], %slot<id>);
	}).List;
}

# One slot's thunk, shielded.  Both bridges promise never to throw, so this is
# belt and braces -- but it is the belt that stops a future edit to either of
# them from turning "one tool failed" into "the batch died and the model has no
# results at all", and on a worker thread the throw would surface at `await` as
# somebody else's problem.
my sub run-slot(%slot) {
	my $answer;
	{
		CATCH {
			default {
				$answer = %(
					role         => 'tool',
					tool_call_id => ~(%slot<id> // ''),
					content      => .message,
					is_error     => True,
				);
			}
		}
		$answer = %slot<work>.();
	}
	$answer;
}

# A de-duplicated answer, filed under the id of the call it is answering. The
# model's own tool_calls entry is the only authority on that id: a result under
# anything else is a conversation the next request is rejected for.
#
# A SHALLOW copy, deliberately: the text is immutable and a structured result
# is a value to be read, not a scratchpad. Two slots sharing one
# structuredContent hash is only a problem for a consumer that mutates a tool
# result in place, which nothing in either bridge's contract permits.
my sub restamp($answer, $id) {
	return $answer unless $answer ~~ Associative;
	my %copy = $answer.Hash;
	%copy<tool_call_id> = ~($id // '');
	%copy;
}

=begin pod

=head1 NAME

MCP::Server::Batch - how a batch of LLM tool calls is executed

=head1 DESCRIPTION

The scheduler behind C<MCP::Server.execute-tool-calls> and
C<MCP::Client.execute-tool-calls>. It is shared so that the two bridges cannot
drift: a toolkit plugged into a local server and the same toolkit reached over
MCP have to answer a batch the same way, in the same order, with the same
number of executions.

=head2 The contract

=item Results come back B<one per slot, in the caller's order>, always. Order
      is never a consequence of how fast a tool answered.

=item A batch runs B<serially> unless every call in it is annotated
      C<readOnlyHint> and C<idempotentHint> (C<concurrency-safe>). One
      unannotated call — a write, a shell command, a question for the user —
      and the whole batch keeps the one-at-a-time ordering it has always had.

=item An eligible batch runs its distinct calls on at most C<:$concurrency>
      workers, and B<identical calls execute once>, the answer copied into
      every slot that asked for it with that slot's own C<tool_call_id>.

=item Nothing is lazy. Every thunk has run by the time this returns.

=head1 EXAMPLES

=begin code :lang<raku>
use MCP::Server::Batch;

my @slots = @calls.map(-> %call {
    my %arguments = %call<arguments>;
    %(
        id         => %call<id>,
        concurrent => concurrency-safe(%annotations{%call<name>}),
        key        => argument-identity(%call<name>, %arguments),
        work       => -> { run-the-tool(%call<name>, %arguments) },
    );
});

my @results = run-tool-batch(@slots, concurrency => 4);
=end code

=head1 SEE ALSO

L<MCP::Server> (the local bridge), C<MCP::Client> (the remote one).

=end pod
