use strict;
use warnings;
use MetaCPAN::V0Shim;
use Plack::Builder;

my $app = MetaCPAN::V0Shim->new->to_app;
builder {
  enable 'SimpleLogger', level => 'warn';
  mount '/v0' => $app;
  mount '/' => $app;
};
