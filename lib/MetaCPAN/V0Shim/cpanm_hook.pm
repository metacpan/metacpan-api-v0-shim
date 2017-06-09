package MetaCPAN::V0Shim::cpanm_hook;
use strict;
use warnings;

use LWP::Protocol::PSGI;
use MetaCPAN::V0Shim;
use Plack::Builder;

my @hooks;

sub import {
  my ($class, @opts) = @_;
  my %opts = map +($_ => 1), @opts;

  my $shim = MetaCPAN::V0Shim->new;

  my $shim_app = builder {
    mount '/v0' => $shim->app;
    mount '/' => $shim->app;
  };
  push @hooks, LWP::Protocol::PSGI->register($shim_app, host => 'api.metacpan.org');
  if ($opts{'disable-metadb'}) {
    my $blocked = sub { [ 500, [], [''] ] };
    push @hooks, LWP::Protocol::PSGI->register($blocked, host => 'cpanmetadb.plackperl.org');
  }
}

sub unimport {
  @hooks = ();
}

1;
