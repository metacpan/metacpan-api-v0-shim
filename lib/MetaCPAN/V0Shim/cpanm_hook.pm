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
  my $shim = MetaCPAN::V0Shim->new(
    ($opts{debug} ? (debug => 1) : ()),
  )->to_app;

  $shim = builder {
    if ($opts{debug}) {
      enable sub {
        my $app = shift;
        return sub {
          my ($env) = @_;
          $env->{'psgi.errors'} = \*STDERR;
          $app->($env);
        };
      };
    }
    enable 'SimpleLogger', level => 'debug';
    mount '/v0' => $shim;
    mount '/' => $shim;
  };
  push @hooks, LWP::Protocol::PSGI->register($shim, host => 'api.metacpan.org');
  if ($opts{'disable-metadb'}) {
    push @hooks, LWP::Protocol::PSGI->register(sub { [500, [], [''] ] }, host => 'cpanmetadb.plackperl.org');
  }
}

sub unimport {
  @hooks = ();
}

1;
