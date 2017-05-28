package MetaCPAN::V0Shim;
use strict;
use warnings;

use JSON::MaybeXS;
use Plack::Builder;
use Plack::Request;
use HTTP::Tiny;
use CPAN::DistnameInfo;
use URI::Escape qw(uri_escape uri_unescape);
use Moo;
use WWW::Form::UrlEncoded qw(build_urlencoded);

our $VERSION = '0.001';

has user_agent => (is => 'ro', default => 'metacpan-api-v0-shim/'.$VERSION);
has ua => (is => 'lazy', default => sub {
  HTTP::Tiny->new(agent => $_[0]->user_agent);
});
has metacpan_url => (is => 'ro', default => 'https://fastapi.metacpan.org/v1/');
has debug => (is => 'ro', default => $ENV{METACPAN_API_V0_SHIM_DEBUG});

sub _deep {
  my ($struct, @path) = @_;
  while (my $path = @path) {
    die "invalid query"
      if ref $struct ne 'HASH' || (keys %$struct) != 1;
    my $path = shift @path;
    return
      if !exists $struct->{$path};
    $struct = $struct->{$path};
  }
  $struct;
}

my $json = JSON::MaybeXS->new(pretty => 1, utf8 => 1, canonical => 1);
sub json_return {
  my ($output, $code, $extra) = @_;
  my %output = %$output;
  ${$extra ||= {}}{info} = 'metacpan-api-v0-shim v'.$VERSION.' - Only supports cpanm 1.7.  See https://github.com/metacpan/metacpan-api/blob/master/docs/API-docs.md for updated API documentation, and the /download_url/ end point for download information';
  $output{x_metacpan_shim} = $extra;
  [
    $code||200,
    [ 'Content-Type' => 'application/json; charset=utf-8' ],
    [ $json->encode(\%output) ],
  ];
}

sub search_return {
  my $items = shift;
  json_return { hits => { hits => $items } }, 200, @_;
}

=head1 NAME

MetaCPAN::V0Shim - Compatibility shim to accomodate cpanm's v0 API usage.

=head1 DESCRIPTION

Serves a compatibility layer that will translate cpanm's use of the metacpan API
into C</download_url/> calls.

=head1 FUNCTIONS

=head2 cpanm_query_to_params

Converts a module query from cpanm to parameters to use in the download_url
endpoint.

A cpanm query looks like:

  {
    "query" : {
      "filtered" : {
        "filter" : {
          "and" : [
            # will be excluded for exact version matches
            { "not" : { "term" : { "status" : "backpan" } } },
            # will be excluded for --dev option
            { "term" : { "maturity" : "released" } }
          ]
        },
        "query" : {
          "nested" : {
            "score_mode" : "max",
            "path" : "module",
            "query" : {
              "custom_score" : {
                "metacpan_script" : "score_version_numified",
                "query" : {
                  "constant_score" : {
                    "filter" : {
                      "and" : [
                        { "term" : { "module.authorized" : true } },
                        { "term" : { "module.indexed" : true } },

                        { "term" : { "module.name" => "My::Module" } },

                        # == versions
                        { "term" : { "module.version" => 1.2 },
                        # >= and other version comparisons, for each rule
                        { "range" : { "module.version_numified" : { "gte" : 1.2 } },
                        # != versions, for each rule
                        { "not" : { "or" : [
                          { "term" : { "module.version_numified" => 1.2 } }
                        ] } }
                      ]
                    }
                  }
                }
              }
            }
          }
        }
      }
    },
    "fields" : [ "date", "release", "author", "module", "status" ]
  }

The query is validated rather strictly against the form cpanm sends, since this
module doesn't really understand Elasticsearch syntax.

The return value will be a hashref with module, version, and dev entries.
Version will be a rule spec as used by L<CPAN::Meta::Spec>, as C</download_url/>
accepts.

=cut

sub cpanm_query_to_params {
  my ($self, $search) = @_;
  my $module;
  my @version;
  my $dev_releases;

  if (my $fields = delete $search->{fields}) {
    my @extra = grep !(
      $_ eq 'date'
      || $_ eq 'release'
      || $_ eq 'author'
      || $_ eq 'module'
      || $_ eq 'status'
      || $_ eq 'module.name'
      || $_ eq 'module.version'
    ), @$fields;
    die { error => "unsupported fields", fields => \@extra }
      if @extra;
  }
  if (my $sort = delete $search->{sort}) {
    my @extra = grep !(
      $_ eq 'date'
      || $_ eq 'module.version_numified'
    ), map keys %$_, @$sort;
    die { error => "unsupported sort fields", fields => \@extra }
      if @extra;
  }

  if (my $query = _deep($search, 'query')) {
    my $filtered = $query->{filtered}
      or die "not a filtered query";

    my $no_backpan;
    if (my $filters = delete $filtered->{filter}) {
      my $and = _deep($filters, 'and')
        or die "unsupported filter";
      for my $filter (@$and) {
        my $status;
        my $maturity;
        if ($status = _deep($filter, qw(not term status)) and $status eq 'backpan') {
          $no_backpan = 1;
          # will be given for exact version matches
        }
        elsif ($maturity = _deep($filter, qw(term maturity)) and $maturity eq 'released') {
          $dev_releases = 0;
        }
        else {
          die "unsupported filter";
        }
      }
    }

    if (!defined $dev_releases && $no_backpan) {
      $dev_releases = 1;
    }

    my $mod_query = _deep($query, qw(filtered query nested));
    die "unsupported filter"
      unless $mod_query->{path} && delete $mod_query->{path} eq 'module';
    die "unsupported filter"
      unless $mod_query->{score_mode} && delete $mod_query->{score_mode} eq 'max';
    my $version_query = _deep($mod_query, qw(query custom_score));
    die "unsupported filter"
      unless
        $version_query->{metacpan_script} && delete $version_query->{metacpan_script} eq 'score_version_numified'
        or $version_query->{script} && delete $version_query->{script} eq "doc['module.version_numified'].value";
    my $mod_filters = _deep($version_query, qw(query constant_score filter and));

    return $self->_parse_module_filters(
      $mod_filters,
      {
        ($dev_releases ? (dev => 1) : ()),
      },
    );
  }
  elsif (
    $search->{query}
      and $search->{query}{match_all}
      and delete $search->{query}
      and my $filters = _deep($search, qw(filter and))
  ) {
    $self->_parse_module_filters($filters, { dev => 1 });
  }
  die "no query found";
}

sub _parse_module_filters {
  my ($self, $filters, $defaults) = @_;

  my $params = { %$defaults };
  my @version;

  for my $filter (@$filters) {
    if (_deep($filter, qw(term module.authorized))) {
      # should always be present
    }
    elsif (_deep($filter, qw(term module.indexed))) {
      # should always be present
    }
    elsif (my $maturity = _deep($filter, qw(term maturity))) {
      if ($maturity eq 'released') {
        delete $params->{dev};
      }
    }
    elsif (my $mod = _deep($filter, qw(term module.name))) {
      $params->{module} = $mod;
    }
    elsif (my $ver = _deep($filter, qw(term module.version))) {
      @version = ("== $ver");
    }
    elsif (
      my $range
        = _deep($filter, qw(range module.version_numified))
        // _deep($filter, qw(range module.version))
    ) {
      for my $cmp (keys %$range) {
        my $ver = $range->{$cmp};
        my %ops = qw(lt < lte <= gt > gte >=);
        my $op = $ops{$cmp}
          or die "unsupported comparison $cmp";
        push @version, "$op $ver";
      }
    }
    elsif (my $nots = _deep($filter, qw(not or))) {
      my @nots = map +(
        _deep($_, qw(term module.version_numified))
        // _deep($_, qw(term module.version))
      ), @$nots;
      push @version, map "!= $_", @nots;
    }
    else {
      die {error => "unsupported filter" , filter => $filter };
    }
  }

  if (@version == 1 && $version[0] =~ s/^>=\s*//) {
    pop @version
      if $version[0] =~ /^0(\.0*)$/;
  }
  elsif (@version > 1) {
    my @ops_order = qw(>= > == != < <=);
    my %ops_order = map +($ops_order[$_], $_), 0 .. $#ops_order;
    @version =
      map $_->[0],
      sort { $a->[1] <=> $b->[1] }
      map [ $_, $ops_order{(/^([<>]=?|[!=]=)/)[0]} ],
      @version;
  }

  if (@version) {
    $params->{version} = join ', ', @version;
  }

  return $params;
}

sub module_query_url {
  my ($self, $params) = @_;
  $params = { %$params };
  my $module = delete $params->{module};
  my $ua = $self->ua;
  my $url = $self->metacpan_url.'download_url/'.$module
    .(%$params ? '?'.build_urlencoded($params) : '');
  return $url;
}

=head2 module_data

Accepts a query structure as given by cpanm, and returns a hashref of module
for a found module.

=cut

sub module_data {
  my ($self, $module, $url) = @_;
  my $ua = $self->ua;
  my $response = $ua->get($url);
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
  return {
    release => $release,
    author => $author,
    date => $data->{date},
    status => $data->{status},
    module => $module,
    version => $data->{version},
    download_url => $data->{download_url},
  };
}

=head2 cpanm_release_to_params

Converts a release query from cpanm to parameters to to find a release url.

A cpanm release query looks like:

  {
    "query" : {
      "filter" : {
        "and" : [
          { "term" : { "release.name" : "Moo-2.002005" } },
          { "term" : { "release.author" : "HAARG" } }
        ]
      }
    },
    "fields" : [ "download_url", "stat", "status" ]
  }

The return value will be a hashref with release and author.

=cut

sub cpanm_release_to_params {
  my ($self, $search) = @_;
  if (my $fields = delete $search->{fields}) {
    my @extra = grep !(
         $_ eq 'download_url'
      || $_ eq 'stat'
      || $_ eq 'status'
      || $_ eq 'version'
    ), @$fields;
    die { error => "unsupported fields", fields => \@extra }
      if @extra;
  }


  my $release;
  my $author;

  if (my $filters = _deep($search, qw(filter and))) {
    for my $filter (@$filters) {
      if (my $rel = _deep($filter, qw(term release.name))) {
        $release = $rel;
      }
      elsif (my $au = _deep($filter, qw(term release.author))) {
        $author = $au;
      }
      else {
        die "unsupported query";
      }
    }
  }
  elsif (my $rel = _deep($search, qw(filter term release.name))) {
    $release = $rel;
  }
  else {
    die "no query found";
  }

  {
    release => $release,
    (defined $author ? (author => $author) : ()),
  };
}

=head2 release_data

Accepts a query structure as given by cpanm, and returns a list of hashrefs
for a given release.

Returned hashrefs will include download_url, stat, and status.

=cut

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

  map +{
    download_url => $_->{fields}{download_url},
    status => $_->{fields}{status},
    stat => $_->{_source}{stat},
    version => $_->{fields}{version},
  }, @$hits;
}

sub _json_handler (&) {
  my ($cb) = @_;
  my $out = eval {
    return $cb->();
  };
  if (my $e = $@) {
    my $code = ref $e && $e->{code};
    my $out = (ref $e && $e->{error}) ? $e : { error => $e };
    return json_return $out, $code || 500;
  }
  $out;
}

sub _module_query {
  my ($self, $params) = @_;
  my $query_url = $self->module_query_url($params);
  my $mod_data = $self->module_data($params->{module}, $query_url)
    or return search_return [], { query => $params, query_url => $query_url };

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
  }], { query => $params, query_url => $query_url };
}

sub file_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  _json_handler {
    my $source = $req->param('source') or die "no source query specified";
    my $params = $self->cpanm_query_to_params($json->decode($source));
    $self->_module_query($params);
  };
}

sub module_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  _json_handler {
    my $module = $req->path;
    $module =~ s{^/}{};
    $module = uri_unescape($module);
    $self->_module_query({ module => $module });
  };
}

sub release_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  _json_handler {
    my $source = $req->param('source');
    my $params = $self->cpanm_release_to_params($json->decode($source));
    search_return [map +{ fields => $_ }, $self->release_data($params)], { query => $params };
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
    my $url = $base_url.uri_escape($path);
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

sub to_app {
  my $self = shift;
  my $debug = $self->debug;
  builder {
    enable sub {
      my $app = shift;
      sub {
        my ($env) = @_;
        my $out = $app->($env);
        if ($debug || $out->[0] >= 500) {
          my $req = Plack::Request->new($env);
          my $error = join('', @{$out->[2]});
          eval { $error = $json->encode($json->decode($error)) };
          my $params = $req->parameters->as_hashref_mixed;
          eval { $_ = $json->decode($_) }
            for values %$params;
          my $request_data = $json->encode({
            uri => $req->base . $req->path_info,
            parameters => $params,
            user_agent => $req->user_agent,
          });
          my $message = "${error}REQUEST: $request_data";
          $message =~ s/(?<!\A)^/    /gm;
          $req->logger->({
            level => ($out->[0] >= 500 ? 'error' : 'debug'),
            message => $message,
          });
        }
        return $out;
      };
    };
    mount '/file/_search' => builder {
      sub { $self->file_search(@_) };
    };
    mount '/module/' => builder {
      mount '/_search' => sub { $self->file_search(@_) };
      mount '/' => sub { $self->module_search(@_) };
    };
    mount '/release/_search' => builder {
      sub { $self->release_search(@_) };
    };
    mount '/pod' => $self->redirect('pod');
    mount '/source' => $self->redirect('source');
    mount '/' => sub { $gone };
  };
}

1;
