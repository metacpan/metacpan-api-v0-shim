package MetaCPAN::V0Shim::Error;
use strict;
use warnings;
use Carp ();
use Exporter qw(import);
use Data::Dumper::Concise ();

our @EXPORT = qw(_die);

use overload
  '""' => '_stringify',
  'bool' => sub () {1},
  fallback => 1,
;

sub new {
  my $class = shift;
  bless {@_}, $class;
}

sub _stringify {
  my %out = %{$_[0]};
  my $error = delete $out{error};
  my $where = delete $out{where};
  if (keys %out) {
    $error .= ': ' . Data::Dumper::Concise::Dumper(\%out);
    $error =~ s/\n*\z//;
  }
  $error .= " at $where\n";
  $error;
}

sub throw {
  my $class = shift;
  die $class->new(@_);
}

sub _die {
  my ($message, @extra) = @_;
  my $where = Carp::shortmess();
  $where =~ s/^ at //;
  $where =~ s/\n+\z//;

  __PACKAGE__->throw(error => $message, where => $where, @extra);
}

1;
