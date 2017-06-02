use strict;
use warnings;
use MetaCPAN::V0Shim;
use Plack::Builder;

my $app = MetaCPAN::V0Shim->new->app;
builder {
  enable 'SimpleLogger', level => 'debug';
  mount '/v0' => $app;
  mount '/' => $app;
};
