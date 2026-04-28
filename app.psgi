use strict;
use warnings;
use MetaCPAN::V0Shim ();
use Plack::Builder   qw( builder enable mount );

my $app = MetaCPAN::V0Shim->new->to_app;
builder {
    enable 'SimpleLogger', level => 'debug';
    mount '/healthcheck' =>
        sub { [ 200, [ 'Content-Type' => 'text/plain' ], ['healthy'] ] };
    mount '/v0' => $app;
    mount '/'   => $app;
};
