package MetaCPAN::V0Shim;
use strict;
use warnings;

use JSON::MaybeXS;
use Plack::Builder;
use Plack::Request;
use HTTP::Tiny;
use CPAN::DistnameInfo;
use URI::Escape qw(uri_escape);
use Moo;

our $VERSION = '0.001';

has user_agent => (is => 'ro', default => 'metacpan-v0-shim/'.$VERSION);
has ua => (is => 'lazy', default => sub {
  HTTP::Tiny->new(agent => $_[0]->user_agent);
});
has metacpan_url => (is => 'ro', default => 'https://fastapi.metacpan.org/v1/');

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

sub json_return {
  my $output = shift;
  my %output = %$output;
  $output{x_metacpan_shim} = 'metacpan-v0-shim v'.$VERSION.' - see /download_url/ for updated API';
  my $code = shift || 200;
  [
    $code,
    [ 'Content-Type' => 'application/json; charset=utf-8' ],
    [ encode_json(\%output) ],
  ];
}

sub search_return {
  my @items = @_;
  json_return { hits => { hits => \@items } };
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
      || $_ eq 'release'
      || $_ eq 'author'
      || $_ eq 'module'
      || $_ eq 'status'
    ), @$fields;
    die "unsupported fields ".join(", ", @extra)
      if @extra;
  }

  my $query = _deep($search, 'query')
    or die "no query found";

  my $filtered = $query->{filtered}
    or die "not a filtered query";

  if (my $filters = delete $filtered->{filter}) {
    my $and = _deep($filters, 'and')
      or die "unsupported filter";
    for my $filter (@$and) {
      my $status;
      my $maturity;
      if ($status = _deep($filter, qw(not term status)) and $status eq 'backpan') {
        # will be given for exact version matches
      }
      elsif ($maturity = _deep($filter, qw(term maturity)) and $maturity eq 'released') {
        $dev_releases = 0;
      }
      else {
        die "unsupported filter";
      }
    }
    $dev_releases = 1
      if not defined $dev_releases;
  }

  my $mod_query = _deep($query, qw(filtered query nested));
  die "unsupported filter"
    unless $mod_query->{path} && delete $mod_query->{path} eq 'module';
  die "unsupported filter"
    unless $mod_query->{score_mode} && delete $mod_query->{score_mode} eq 'max';
  my $version_query = _deep($mod_query, qw(query custom_score));
  die "unsupported filter"
    unless delete $version_query->{metacpan_script} eq 'score_version_numified';
  my $mod_filters = _deep($version_query, qw(query constant_score filter and));

  for my $filter (@$mod_filters) {
    if (_deep($filter, qw(term module.authorized))) {
      # should always be present
    }
    elsif (_deep($filter, qw(term module.indexed))) {
      # should always be present
    }
    elsif (my $mod = _deep($filter, qw(term module.name))) {
      $module = $mod;
    }
    elsif (my $ver = _deep($filter, qw(term module.version))) {
      @version = ("== $ver");
    }
    elsif (my $range = _deep($filter, qw(range module.version_numified))) {
      die "invalid range"
        if (keys %$range) != 1;
      my ($cmp, $ver) = %$range;
      my %ops = qw(lt < lte <= gt > gte >=);
      my $op = $ops{$cmp}
        or die "unsupported comparison $cmp";
      push @version, "$op $ver";
    }
    elsif (my $nots = _deep($filter, qw(not or))) {
      my @nots = map _deeps($_, qw(term module.version_numified)), @$nots;
      push @version, map "!= $_", @nots;
    }
    else {
      die "unsupported filter";
    }
  }
  if (@version == 1 && $version[0] =~ s/^>=\s*//) {
    pop @version
      if $version[0] =~ /^0(\.0*)$/;
  }
  {
    module => $module,
    (@version ? (version => join ', ', @version) : ()),
    ($dev_releases ? (dev => 1) : ()),
  };
}

=head2 module_data

Accepts a query structure as given by cpanm, and returns a hashref of module
for a found module.

=cut

sub module_data {
  my ($self, $params) = @_;
  my $module = delete $params->{module};
  my $ua = $self->ua;
  my $url = $self->metacpan_url.'download_url/'.$module
    .(%$params ? '?'.$ua->www_form_urlencode($params) : '');
  my $response = $ua->get($url);
  if (!$response->{success}) {
    my $error = $response->{content};
    eval { $error = json_decode($error) };
    die $error;
  }
  my $data = decode_json($response->{content});
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
    ), @$fields;
    die "unsupported fields ".join(", ", @extra)
      if @extra;
  }

  my $filters = _deep($search, qw(filter and))
    or die "no query found";

  my $release;
  my $author;
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

  {
    release => $release,
    author => $author,
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
    fields => [ 'download_url', 'status' ],
  };

  my $ua = $self->ua;
  my $response = $ua->post($self->metacpan_url.'release/_search', {
    headers => { 'Content-Type' => 'application/json; charset=utf-8' },
    content => encode_json($query),
  });
  if (!$response->{success}) {
    my $error = $response->{content};
    eval { $error = json_decode($error) };
    die $error;
  }

  my $data = decode_json($response->{content});
  my $hits = $data->{hits}{hits} || die $data;

  map +{
    download_url => $_->{fields}{download_url},
    status => $_->{fields}{status},
    stat => $_->{_source}{stat},
  }, @$hits;
}

sub file_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);

  my $out = eval {
    my $source = $req->param('source');
    my $params = $self->cpanm_query_to_params(decode_json($source));
    my $mod_data = $self->module_data($params)
      or return search_return;

    search_return {
      _score => 1,
      fields => {
        release => $mod_data->{release},
        author => $mod_data->{author},
        data => $mod_data->{date},
        status => $mod_data->{status},
        module => [
          {
            name => $mod_data->{module},
            version => $mod_data->{version},
          },
        ],
      },
    };
  };
  if ($@) {
    return json_return {
      error => $@,
    }, 500;
  }
  $out;
}

sub release_search {
  my ($self, $env) = @_;
  my $req = Plack::Request->new($env);
  my $out = eval {
    my $source = $req->param('source');
    my $params = $self->cpanm_release_to_params(decode_json($source));
    search_return map +{ fields => $_ }, $self->release_data($params);
  };
  if ($@) {
    return json_return {
      error => $@,
    }, 500;
  }
  $out;
}

sub redirect {
  my ($self, $base) = @_;
  my $metacpan_url = $self->metacpan_url;
  my $base_url = $metacpan_url.$base.'/';
  sub {
    my $env = shift;
    my $url = $base_url.uri_escape($env->{PATH_INFO});
    $url .= '?'.$env->{QUERY_STRING}
      if defined $env->{QUERY_STRING} && length $env->{QUERY_STRING};
    [ 301, [ 'Location' => $url ], ['Moved'] ];
  };
}

my $gone = [410, ['Content-Type' => 'text/plain'], ['Gone']];

sub cpanm_only {
  sub {
    my $app = shift;
    sub {
      my $env = shift;
      return $gone
        if $env->{HTTP_USER_AGENT} !~ /\bcpanminus\b/;
      $app->($env);
    }
  };
}

sub to_app {
  my $self = shift;
  builder {
    mount '/file/_search' => builder {
      enable cpanm_only;
      sub { $self->file_search(@_) };
    };
    mount '/release/_search' => builder {
      enable cpanm_only;
      sub { $self->release_search(@_) };
    };
    mount '/pod' => $self->redirect('pod');
    mount '/source' => $self->redirect('source');
    mount '/' => sub { $gone };
  };
}

1;
