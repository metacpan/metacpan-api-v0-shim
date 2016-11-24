use strict;
use warnings;

use JSON::MaybeXS;
use Plack::Builder;
use Plack::Request;
use WWW::Form::UrlEncoded qw/build_urlencoded/;
use HTTP::Tiny;
use CPAN::DistnameInfo;

sub cpanm_query_to_params {
  my $search = shift;
  my $query = $search->{query}{filtered};
  my $dev_releases;
  if ($query->{filter}) {
    my $filter = $query->{filter}{and};
    if (!grep { $_->{term} && $_->{term}{maturity} && $_->{term}{maturity} eq 'released' } @$filter) {
      $dev_releases = 1;
    }
  }
  my $module;
  my @version;
  my $mod_query = $query->{query}{nested}{query}{custom_score}{query}{constant_score}{filter}{and};
  for my $rule (@$mod_query) {
    if (my $term = $rule->{term}) {
      $module = $term->{'module.name'}
        if $term->{'module.name'};
      @version = ('== '. $term->{'module.version'})
        if $term->{'module.version'};
    }
    elsif (my $range = $rule->{range}) {
      my $range_rule = $range->{'module.version_numified'};
      my ($cmp, $ver) = %$range_rule;
      my %ops = qw(lt < lte <= gt > gte >=);
      my $op = $ops{$cmp};
      push @version, "$op $ver";
    }
    elsif (my $not = $rule->{not}) {
      my @nots = map { $_->{term}{'module.version_numified'} } @{$not->{or}};
      push @version, map "!= $_", @nots;
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

sub json_return {
  my $output = shift;
  my $code = shift || 200;
  [
    $code,
    [ 'Content-Type' => 'application/json; charset=utf-8' ],
    [ encode_json($output) ],
  ];
}

my $ua = HTTP::Tiny->new(
  agent => 'metacpan-shim/v0'
);
my $gone = [410, ['Content-Type' => 'text/plain'], ['Gone']];
builder {
  mount '/v0/file/_search' => sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    return $gone
      if $req->user_agent !~ /cpanminus/;

    my $source = $req->param('source');
    my $search = decode_json($source);
    my $params = cpanm_query_to_params($search);
    my $module = delete $params->{module};
    my $url = 'https://fastapi.metacpan.org/download_url/'.$module
      .(%$params ? '?'.build_urlencoded(%$params) : '');
    my $response = $ua->get($url);
    my $data = decode_json($response->{content});
    if (!$data->{download_url}) {
      return json_return { hits => { hits => [] } };
    }
    (my $path = $data->{download_url}) =~ s{.*/authors/}{authors/};
    my $info = CPAN::DistnameInfo->new($path);
    my $author = $info->cpanid;
    my $release = $info->distvname;
    json_return {
      hits => {
        hits => [
          {
            _score => 1,
            fields => {
              release => $release,
              author => $author,
              data => $data->{date},
              status => $data->{status},
              module => [
                {
                  name => $module,
                  version => $data->{version},
                },
              ],
            },
          },
        ],
      },
    };
  };
  mount '/v0/release/_search' => sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    return $gone
      if $req->user_agent !~ /cpanminus/;
    my $source = $req->param('source');
    my $search = decode_json($source);

    my $release;
    my $author;
    for my $term (map $_->{term}, @{$search->{filter}{and}}) {
      $release = $term->{'release.name'}
        if $term->{'release.name'};
      $author = $term->{'release.author'}
        if $term->{'release.author'};
    }

    my $query = {
      filter => {
        bool => {
          must => [
            { term => { name => $release } },
            { term => { author => $author } },
          ],
        },
      },
      _source => [ 'stat' ],
      fields => [ 'download_url', 'status' ],
    };
    my $release_json = $ua->post('https://fastapi.metacpan.org/v1/release/_search', {
      headers => { 'Content-Type' => 'application/json; charset=utf-8' },
      content => encode_json($query),
    });
    my $release_data = decode_json($release_json->{content});
    json_return {
      hits => {
        hits => [
          map {;
            {
              fields => {
                download_url => $_->{fields}{download_url},
                status => $_->{fields}{status},
                stat => $_->{_source}{stat},
              },
            };
          }
          @{$release_data->{hits}{hits}},
        ],
      },
    };
  };
  mount '/pod' => sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    my $wanted = $req->path_info;
    my $url = 'https://fastapi.metacpan.org/pod/'.URI::Escape::uri_escape($wanted);
    $url .= '?'.$req->query_string
      if defined $req->query_string && length $req->query_string;
    [ 301, [ 'Location' => $url ], ['Moved'] ];
  };
  mount '/source' => sub {
    my $env = shift;
    my $req = Plack::Request->new($env);
    my $wanted = $req->path_info;
    my $url = 'https://fastapi.metacpan.org/source/'.URI::Escape::uri_escape($wanted);
    $url .= '?'.$req->query_string
      if defined $req->query_string && length $req->query_string;
    [ 301, [ 'Location' => $url ], ['Moved'] ];
  };
  mount '/' => sub {
    $gone;
  };
};
