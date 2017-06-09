use strict;
use warnings;
use MetaCPAN::V0Shim;
use Plack::Builder;

$ENV{PLACK_SERVER} ||= eval {
  require Plack::Handler::Net::Async::HTTP::Server;
  'Net::Async::HTTP::Server';
} || undef;

my $app = MetaCPAN::V0Shim->new->app;
builder {
  mount '/v0' => $app;
  mount '/' => $app;
};
