use MCP::Server::Transport;

#| Stdio transport: newline-framed JSON-RPC on stdin/stdout, which is what an
#| MCP client that spawns a server process speaks.
unit class MCP::Server::Transport::Stdio does MCP::Server::Transport;

# Writes come from the run loop and from any thread that logs or notifies (a
# handler on an HTTP pool thread, a Supply.interval flusher pushing background
# output), so a message has to reach the pipe whole or the client's stream loses
# its framing for good.  MoarVM does serialise a single write on one handle
# today -- t/25 hammers this from eight threads and sees no tearing with the
# lock taken out -- but that is an undocumented VM detail rather than a promise
# the language makes, it says nothing about the print/flush pair being one unit,
# and the Transport role asks implementations for the guarantee outright.  An
# uncontended Lock costs nothing next to the write syscall, so we take it.
has Lock $!write-lock .= new;

method read-message(--> Str) {
	my $line = $*IN.get;
	return Str unless $line.defined;
	$line;
}

method write-message(Str:D $msg) {
	$!write-lock.protect: {
		$*OUT.print($msg);
		$*OUT.flush;
	}
}
