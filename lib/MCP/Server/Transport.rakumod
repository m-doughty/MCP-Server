#| The stream-shaped transport contract: read one framed message, write one
#| framed message.  C<MCP::Server.run> drives C<read-message> from a single
#| loop, so reads are never concurrent.
#|
#| B<Writes are.>  C<MCP::Server.log> and C<MCP::Server.notify> write on
#| whichever thread called them — a tool handler running on a pool thread, a
#| C<Supply.interval> flusher pushing background-job output — while the run loop
#| may be writing a response for a different request at the same moment.  An
#| implementation must therefore serialise C<write-message> so that two messages
#| can never be spliced into each other: a torn JSON-RPC line is unparseable, and
#| the client has no way to resynchronise a stream that has lost its framing.
unit role MCP::Server::Transport;

method read-message(--> Str) { ... }
method write-message(Str:D $msg) { ... }
