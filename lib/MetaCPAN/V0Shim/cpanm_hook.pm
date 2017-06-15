package MetaCPAN::V0Shim::cpanm_hook;
use strict;
use warnings;

use LWP::Protocol::PSGI;
use MetaCPAN::V0Shim;
use Plack::Builder;
use Log::Contextual qw( set_logger );
use Log::Log4perl ();

my @hooks;

sub import {
  my ($class, %opts) = @_;
  return if @hooks;
  if (!Log::Log4perl->initialized) {
    Log::Log4perl->init(\<<'EOT');
      log4perl.category = WARN, Screen

      log4perl.appender.Screen = Log::Log4perl::Appender::ScreenColoredLevels
      log4perl.appender.Screen.layout = Log::Log4perl::Layout::PatternLayout
      log4perl.appender.Screen.layout.ConversionPattern = [%p] %m%n
EOT
  }

  my $logger = Log::Log4perl->get_logger('MetaCPAN::V0Shim');
  $logger->level(Log::Log4perl::Level::to_priority(uc $opts{log_level}))
    if $opts{log_level};
  set_logger($logger);

  my $shim = MetaCPAN::V0Shim->new;
  my $shim_app = builder {
    mount '/v0' => $shim->app;
    mount '/' => $shim->app;
  };

  push @hooks, LWP::Protocol::PSGI->register($shim_app, host => 'api.metacpan.org');
  if ($opts{'disable_metadb'}) {
    my $blocked = sub { [ 500, [], [''] ] };
    push @hooks, LWP::Protocol::PSGI->register($blocked, host => 'cpanmetadb.plackperl.org');
  }
}

sub unimport {
  @hooks = ();
}

1;
