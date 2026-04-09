use MCP::Server::Transport;

unit class MCP::Server::Transport::Stdio does MCP::Server::Transport;

method read-message(--> Str) {
	my $line = $*IN.get;
	return Str unless $line.defined;
	$line;
}

method write-message(Str:D $msg) {
	$*OUT.print($msg);
	$*OUT.flush;
}
