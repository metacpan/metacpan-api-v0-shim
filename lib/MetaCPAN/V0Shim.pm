package MetaCPAN::V0Shim;
use strict;
use warnings;

use JSON::MaybeXS;
use Plack::Builder;
use Plack::Request;
use HTTP::Tiny;
use CPAN::DistnameInfo;
use WWW::Form::UrlEncoded qw(build_urlencoded);
use URL::Encode qw(url_decode url_encode);
use Log::Contextual::Easy::Default;

use MetaCPAN::V0Shim::Error;
use MetaCPAN::V0Shim::Parser;

use Moo;

our $VERSION = '0.001';

has user_agent => (is => 'ro', default => 'metacpan-api-v0-shim/'.$VERSION);
has ua => (is => 'lazy', default => sub {
  HTTP::Tiny->new(agent => $_[0]->user_agent);
});
has metacpan_url => (is => 'ro', default => 'https://fastapi.metacpan.org/v1/');
has app => (is => 'lazy');

my $json = JSON::MaybeXS->new(pretty => 1, utf8 => 1, canonical => 1);

sub search_return {
  { hits => { hits => $_[0] } };
}

sub module_query_url {
  my ($self, $params) = @_;
  $params = { %$params };
  my $module = delete $params->{module};
  return $self->metacpan_url.'download_url/'.$module
    .(%$params ? '?'.build_urlencoded($params) : '');
}

sub module_data {
  my ($self, $params) = @_;
  my $url = $self->module_query_url($params);
  my $response = $self->ua->get($url);
  if (!$response->{success}) {
    my $error = $response->{content};
    eval { $error = $json->decode($error) };
    if (ref $error && $error->{code} == 404) {
      return;
    }
    die $error;
  }
  my $data = $json->decode($response->{content});
  if (!$data->{download_url}) {
    return;
  }
  (my $path = $data->{download_url}) =~ s{.*/authors/}{authors/};
  my $info = CPAN::DistnameInfo->new($path);
  my $author = $info->cpanid;
  my $release = $info->distvname;
  DlogS_info { "result: $_" } {
    release => $release,
    author => $author,
    date => $data->{date},
    status => $data->{status},
    module => $params->{module},
    version => $data->{version},
    download_url => $data->{download_url},
  };
}

sub release_data {
  my ($self, $params) = @_;
  my $query = {
    filter => {
      bool => {
        must => [
          { term => { name => $params->{release} } },
          ($params->{author} ? ( { term => { author => $params->{author} } } ) : ()),
        ],
      },
    },
    _source => [ 'stat' ],
    fields => [ 'download_url', 'status', 'version' ],
  };

  my $ua = $self->ua;
  my $response = $ua->post($self->metacpan_url.'release/_search', {
    headers => { 'Content-Type' => 'application/json; charset=utf-8' },
    content => $json->encode($query),
  });
  if (!$response->{success}) {
    my $error = $response->{content};
    eval { $error = $json->decode($error) };
    die $error;
  }

  my $data = $json->decode($response->{content});
  my $hits = $data->{hits}{hits} || die $data;

  Dlog_info { "result: $_" } map +{
    download_url => $_->{fields}{download_url},
    status => $_->{fields}{status},
    stat => $_->{_source}{stat},
    version => $_->{fields}{version},
  }, @$hits;
}

sub _json_handler (&) {
  my ($cb) = @_;
  my $context = {
    info => 'metacpan-api-v0-shim v'.$VERSION.' - Only supports cpanm 1.7.  See https://github.com/metacpan/metacpan-api/blob/master/docs/API-docs.md for updated API documentation, and the /download_url/ end point for download information',
  };
  my $code = 200;

  my $out;
  if (!eval { $out = $cb->($context); 1 }) {
    $code = ref $@ && $@->{code} || 500;
    $out = (ref $@ && $@->{error}) ? { %{ $@ } } : { error => $@ };
  }

  $out->{x_metacpan_shim} = $context;
  [
    $code,
    [ 'Content-Type' => 'application/json; charset=utf-8' ],
    [ $json->encode($out) ],
  ];
}

sub _module_query {
  my ($self, $params) = @_;
  my $mod_data = $self->module_data($params)
    or return search_return [];

  my $date = $mod_data->{date};
  $date =~ s/Z?\z/Z/;
  search_return [{
    _score => 1,
    fields => {
      release => $mod_data->{release},
      author => $mod_data->{author},
      date => $date,
      status => $mod_data->{status},
      module => [
        {
          name => $mod_data->{module},
          version => $mod_data->{version},
        },
      ],
      'module.name' => $mod_data->{module},
      'module.version' => $mod_data->{version},
    },
  }];
}

sub file_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  _json_handler {
    my $context = shift;
    my $source = $req->param('source') or _die "no source query specified";
    my $query = $json->decode($source);
    my $params = parse_module_query($query);

    $context->{query} = $params;
    $context->{query_url} = $self->module_query_url($params);
    $self->_module_query($params);
  };
}

sub module_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  _json_handler {
    my $context = shift;
    my $module = $req->path;
    $module =~ s{^/}{};
    $module = url_decode($module);
    my $params = {
      module => $module,
    };
    $context->{query} = $params;
    $context->{query_url} = $self->module_query_url($params);
    my $mod_data = $self->module_data($params)
      or die { code => 404 };
    return {
      release => $mod_data->{release},
    };
  };
}

sub release_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  _json_handler {
    my $context = shift;
    my $source = $req->param('source');
    my $params = parse_release_query($json->decode($source));
    $context->{query} = $params;
    my @releases = $self->release_data($params);
    search_return [map +{ fields => $_ }, @releases];
  };
}

sub redirect {
  my ($self, $base) = @_;
  my $metacpan_url = $self->metacpan_url;
  my $base_url = $metacpan_url.$base.'/';
  sub {
    my $env = shift;
    my $path = $env->{PATH_INFO};
    $path =~ s{^/}{};
    my $url = $base_url.url_encode($path);
    $url .= '?'.$env->{QUERY_STRING}
      if defined $env->{QUERY_STRING} && length $env->{QUERY_STRING};
    [ 301, [ 'Location' => $url ], ['Moved'] ];
  };
}

my $gone = [410, ['Content-Type' => 'text/html'], [<<'END_HTML']];
<!DOCTYPE html>
<html>
    <head>
        <title>MetaCPAN v0 API</title>
        <style type="text/css">
            body {
                font-family: sans-serif;
            }
        </style>
        <link rel="shortcut icon" href="https://metacpan.org/static/icons/favicon.ico">
    </head>
    <body>
        <h1>MetaCPAN v0 API has been has been shut down!</h1>
        <p>
            See the <a href="https://github.com/metacpan/metacpan-api/blob/master/docs/API-docs.md">MetaCPAN v1 API</a> should be used instead.
        </p>
    </body>
</html>

END_HTML

sub _build_app {
  my $self = shift;
  builder {
    enable sub {
      my $app = shift;
      sub {
        my ($env) = @_;
        my $req = Plack::Request->new($env);
        log_debug { "REQUEST: " . $req->base . $req->path_info . "  AGENT: " . $req->user_agent };
        log_debug {
          my $params = $req->parameters->as_hashref_mixed;
          eval { $_ = $json->decode($_) }
            for values %$params;
          "PARAMETERS: ". $json->encode($params);
        };
        my $out = $app->($env);
        if ($out->[0] >= 500) {
          log_error { $out->[0] . ': ' . join('', @{$out->[2]}) };
        }
        return $out;
      };
    };
    mount '/file/_search' => sub { $self->file_search(@_) };
    mount '/module/' => builder {
      mount '/_search' => sub { $self->file_search(@_) };
      mount '/' => sub { $self->module_search(@_) };
    };
    mount '/release/_search' => sub { $self->release_search(@_) };
    mount '/pod' => $self->redirect('pod');
    mount '/source' => $self->redirect('source');
    mount '/' => sub { $gone };
  };
}

1;
__END__

=head1 NAME

MetaCPAN::V0Shim - Compatibility shim to accomodate cpanm's v0 API usage.

=head1 DESCRIPTION

Serves a compatibility layer that will translate cpanm's use of the metacpan API
into C</download_url/> calls.

=head1 FUNCTIONS

=head2 module_data

Accepts a query structure as given by cpanm, and returns a hashref of module
for a found module.

=head2 release_data

Accepts a query structure as given by cpanm, and returns a list of hashrefs
for a given release.

Returned hashrefs will include download_url, stat, and status.

=cut
