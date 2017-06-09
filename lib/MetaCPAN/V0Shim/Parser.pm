package MetaCPAN::V0Shim::Parser;
use strict;
use warnings;

use Log::Contextual::Easy::Default;
use MetaCPAN::V0Shim::Error;
use Exporter qw(import);

our @EXPORT = qw(parse_module_query parse_release_query);

sub _deep {
  my ($struct, @path) = @_;
  while (my $path = @path) {
    _die "invalid query", $path
      if ref $struct ne 'HASH' || (keys %$struct) != 1;
    my $path = shift @path;
    return
      if !exists $struct->{$path};
    $struct = $struct->{$path};
  }
  $struct;
}

sub parse_module_query {
  my ($search) = @_;
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
    _die "unsupported fields", fields => \@extra
      if @extra;
  }
  if (my $sort = delete $search->{sort}) {
    my @extra = grep !(
      $_ eq 'date'
      || $_ eq 'module.version_numified'
    ), (ref $sort eq 'HASH' ? keys %$sort : map keys %$_, @$sort);
    _die "unsupported sort fields", fields => \@extra
      if @extra;
  }

  if ($search->{query} and $search->{query}{match_all}) {
    delete $search->{query};
  }

  if (my $query = _deep($search, 'query')) {
    my $dev_releases;
    if (my $filtered = $query->{filtered}) {
      my $no_backpan;
      if (my $filters = delete $filtered->{filter}) {
        my $and = _deep($filters, 'and')
          // (_deep($filters, 'term') && [$filters])
          or _die "unsupported filters", filters => $filters;
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
            _die "unsupported filter", filters => $filter;
          }
        }
      }

      if (!defined $dev_releases && $no_backpan) {
        $dev_releases = 1;
      }
    }

    my $mod_query
      = _deep($query, qw(filtered query nested))
      || _deep($query, qw(nested))
      or _die "no nested query", query => $query;

    _die "unsupported filter", query => $mod_query
      unless $mod_query->{path} && delete $mod_query->{path} eq 'module';
    _die "unsupported filter", query => $mod_query
      unless $mod_query->{score_mode} && delete $mod_query->{score_mode} eq 'max';
    my $version_query = _deep($mod_query, qw(query custom_score));
    _die "unsupported version filter", query => $version_query
      unless
        $version_query->{metacpan_script} && delete $version_query->{metacpan_script} eq 'score_version_numified'
        or $version_query->{script} && delete $version_query->{script} eq "doc['module.version_numified'].value";
    my $mod_filters = _deep($version_query, qw(query constant_score filter and));

    return _parse_module_filters(
      $mod_filters,
      {
        ($dev_releases ? (dev => 1) : ()),
      },
    );
  }
  elsif (my $filters = _deep($search, qw(filter and))) {
    return _parse_module_filters($filters, { dev => 1 });
  }
  _die "no query found", search => $search;
}

sub _parse_module_filters {
  my ($filters, $defaults) = @_;

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
          or _die "unsupported comparison", op => $cmp;
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
      _die "unsupported filter", filter => $filter;
    }
  }

  @version = grep !/^(?:>=\s*)?0(?:\.0+)$/, @version;

  if (@version == 1) {
    $version[0] =~ s/^(?:>=\s*)?//;
  }
  elsif (@version > 1) {
    my @ops_order = qw(>= > == != < <=);
    my %ops_order = map +($ops_order[$_], $_), 0 .. $#ops_order;
    @version =
      map $_->[0],
      sort { $a->[1] <=> $b->[1] || $a->[2] cmp $b->[2] }
      map {
          /^([<>!=]=?)\s*(.*)/;
          [ $_, $ops_order{$1}, $2 ],
      }
      @version;
  }

  if (@version) {
    $params->{version} = join ', ', @version;
  }

  Dlog_info { "module query: $_" } $params;
  return $params;
}

sub parse_release_query {
  my ($search) = @_;
  if (my $fields = delete $search->{fields}) {
    my @extra = grep !(
         $_ eq 'download_url'
      || $_ eq 'stat'
      || $_ eq 'status'
      || $_ eq 'version'
    ), @$fields;
    _die "unsupported fields", fields => \@extra
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
        _die "unsupported query", filter => $filter;
      }
    }
  }
  elsif (my $rel = _deep($search, qw(filter term release.name))) {
    $release = $rel;
  }
  else {
    _die "unsupported query", query => $search;
  }

  DlogS_info { "release query: $_" } {
    release => $release,
    (defined $author ? (author => $author) : ()),
  };
}

1;
__END__

=head1 NAME

MetaCPAN::V0Shim::Parser - Parse cpanm's MetaCPAN queries

=head1 FUNCTIONS

=head2 parse_module_query

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

=head2 parse_release_query

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