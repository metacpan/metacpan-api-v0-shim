package MetaCPAN::V0Shim;
use strict;
use warnings;

use JSON::MaybeXS;
use Plack::Builder;
use Plack::Request;
use Plack::Util;
use CPAN::DistnameInfo;
use WWW::Form::UrlEncoded qw(build_urlencoded);
use URL::Encode qw(url_decode url_encode);
use Net::Async::HTTP;
use IO::Async::Loop;
use IO::Async::SSL;
use IO::Socket::SSL qw(SSL_VERIFY_PEER);
use Log::Contextual::Easy::Default;
use Future;

use MetaCPAN::V0Shim::Error;
use MetaCPAN::V0Shim::Parser;

use Moo;

our $VERSION = '0.001';

has user_agent => (is => 'ro', default => 'metacpan-api-v0-shim/'.$VERSION);
has loop => (is => 'lazy', default => sub { IO::Async::Loop->new });
has notifier => (is => 'lazy', default => sub {
  my $self = shift;
  my $notifier = IO::Async::Notifier->new;
  $self->loop->add($notifier);
  return $notifier;
});
has ua => (is => 'lazy', default => sub {
  my $self = shift;
  my $http = Net::Async::HTTP->new(
    max_connections_per_host => 4,
    timeout => 10,
    decode_content => 1,
    SSL_verify_mode => SSL_VERIFY_PEER,
  );
  $self->loop->add($http);
  return $http;
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

my $decode = sub {
  my $response = shift;
  my $content = $response->content;
  if ($response->is_error) {
    my $error = $content;
    eval { $error = $json->decode($error) };
    if (ref $error && $error->{code} == 404) {
      return Future->done;
    }
    return Future->fail($error);
  }
  Future->done($json->decode($content));
};

sub module_data {
  my ($self, $params) = @_;
  my $url = $self->module_query_url($params);

  $self->ua->GET($url)->then($decode)->then(sub {
    my $data = shift || return Future->done;
    if (!$data->{download_url}) {
      return;
    }
    my $path = $data->{download_url} =~ s{.*/authors/}{authors/}r;
    my $info = CPAN::DistnameInfo->new($path);
    my $author = $info->cpanid;
    my $release = $info->distvname;
    my $date = $data->{date};
    $date =~ s/Z?\z/Z/;
    my $result = {
      release => $release,
      author => $author,
      date => $date,
      status => $data->{status},
      module => $params->{module},
      version => $data->{version},
      download_url => $data->{download_url},
    };
    DlogS_info { "result: $_" } $result;
    Future->done($result);
  });
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

  $self->ua->POST(
    $self->metacpan_url.'release/_search',
    $json->encode($query),
    content_type => 'application/json; charset=utf-8',
  )->then($decode)->then(sub {
    my $data = shift;
    my $hits = $data->{hits}{hits} or die $data;
    Future->done(
      Dlog_info { "result: $_" } map +{
        download_url => $_->{fields}{download_url},
        status => $_->{fields}{status},
        stat => $_->{_source}{stat},
        version => $_->{fields}{version},
      }, @$hits
    );
  });
}

sub _json_handler {
  my ($self, $env, $cb) = @_;

  my $context = {
    info => (<<"END_INFO" =~ s{\n}{ }r),
metacpan-api-v0-shim v$VERSION - Only supports cpanm 1.7.
See https://github.com/metacpan/metacpan-api/blob/master/docs/API-docs.md for
updated API documentation, and the /download_url/ end point for download
information.
END_INFO
  };

  my $delayed = sub {
    my $responder = shift;

    my $future = Future->call(sub {
      Future->wrap($cb->($context));
    })->then(
      sub {
        my $out = shift;
        Future->done(200, $out);
      },
      sub {
        my $error = shift;
        my $code = ref $error && $error->{code} || 500;
        my $out = (ref $error && $error->{error}) ? { %{ $error } } : { error => $error };
        Future->done($code, $out);
      },
    )->then(sub {
      my ($code, $out) = @_;
      $out->{x_metacpan_shim} = $context;
      Future->done([
        $code,
        [ 'Content-Type' => 'application/json; charset=utf-8' ],
        [ $json->encode($out) ],
      ]);
    })->then(sub {
      $responder->(@_);
      Future->done;
    })->else_done;
    $self->notifier->adopt_future($future);
    $future->get
      unless $env->{'psgi.nonblocking'};
  };
  return $delayed
    if $env->{'psgi.streaming'};
  my $out;
  $delayed->(sub { $out = $_[0] });
  return $out;
}

sub file_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  $self->_json_handler($env, sub {
    my $context = shift;
    my $source = $req->param('source') or _die "no source query specified";
    my $query = $json->decode($source);
    my $params = parse_module_query($query);

    $context->{query} = $params;
    $context->{query_url} = $self->module_query_url($params);

    $self->module_data($params)->then(sub {
      Future->done( search_return [ map +{
        _score => 1,
        fields => {
          release => $_->{release},
          author => $_->{author},
          date => $_->{date},
          status => $_->{status},
          module => [
            {
              name => $_->{module},
              version => $_->{version},
            },
          ],
          'module.name' => $_->{module},
          'module.version' => $_->{version},
        },
      }, @_] );
    });
  });
}

sub module_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  $self->_json_handler($env, sub {
    my $context = shift;
    my $module = $req->path;
    $module =~ s{^/}{};
    $module = url_decode($module);
    my $params = {
      module => $module,
    };
    $context->{query} = $params;
    $context->{query_url} = $self->module_query_url($params);

    $self->module_data($params)->then(sub {
      if (@_) {
        Future->done(map +{
          release => $_->{release},
        }, @_);
      }
      else {
        Future->fail({ error => 'module not found', code => 404 });
      }
    });
  });
}

sub release_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  $self->_json_handler($env, sub {
    my $context = shift;
    my $source = $req->param('source');
    my $params = parse_release_query($json->decode($source));
    $context->{query} = $params;
    $self->release_data($params)->then(sub {
      Future->done( search_return [map +{ fields => $_ }, @_] );
    });
  });
}

sub redirect {
  my ($self, $base, $env) = @_;
  my $metacpan_url = $self->metacpan_url;
  my $base_url = $metacpan_url.$base.'/';
  my $path = $env->{PATH_INFO};
  $path =~ s{^/}{};
  my $url = $base_url.url_encode($path);
  $url .= '?'.$env->{QUERY_STRING}
    if defined $env->{QUERY_STRING} && length $env->{QUERY_STRING};
  [ 301, [ 'Location' => $url ], ['Moved'] ];
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

sub log_wrap {
  my ($self, $app) = @_;
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
    return Plack::Util::response_cb($app->($env), sub {
      my $res = shift;
      if ($res->[0] >= 500) {
        log_error { $res->[0] . ': ' . join('', @{$res->[2]}) };
      }
    });
  };
}

sub _build_app {
  my $self = shift;
  builder {
    enable sub { $self->log_wrap(@_) };
    mount '/file/_search'     => sub { $self->file_search(@_) };
    mount '/module/_search'   => sub { $self->file_search(@_) };
    mount '/module/'          => sub { $self->module_search(@_) };
    mount '/release/_search'  => sub { $self->release_search(@_) };
    mount '/pod'    => sub { $self->redirect('pod', @_) };
    mount '/source' => sub { $self->redirect('source', @_) };
    mount '/'       => sub { $gone };
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
