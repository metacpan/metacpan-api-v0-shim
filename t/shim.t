use strict;
use warnings;
use Test::More;
use Plack::Test;
use HTTP::Request::Common;
use MetaCPAN::V0Shim;
use JSON::MaybeXS;
use WWW::Form::UrlEncoded qw(build_urlencoded parse_urlencoded);

my $json = JSON::MaybeXS->new(utf8 => 1, canonical => 1);
my $app = MetaCPAN::V0Shim->new->to_app;
{
  my $wrap_app = $app;
  $app = sub {
    my ($env) = @_;
    $env->{'psgix.logger'} = sub {};
    $wrap_app->($env);
  };
}
my $test = Plack::Test->create($app);

sub req {
  my ($url, $query) = @_;
  if ($query) {
    $url .= '?' . build_urlencoded(source => $json->encode($query));
  }
  my $res = $test->request(GET $url);
  $json->decode($res->content);
}

my $res = req('/file/_search', {
  'fields' => [
    'date',
    'release',
    'author',
    'module',
    'status',
  ],
  'query' => {
    'filtered' => {
      'query' => {
        'nested' => {
          'query' => {
            'custom_score' => {
              'query' => {
                'constant_score' => {
                  'filter' => {
                    'and' => [
                      {
                        'term' => {
                          'module.authorized' => \1,
                        },
                      },
                      {
                        'term' => {
                          'module.indexed' => \1,
                        },
                      },
                      {
                        'term' => {
                          'module.name' => 'Perl::Version',
                        },
                      },
                      {
                        'term' => {
                          'module.version_numified' => '1.013030',
                        },
                      },
                    ],
                  },
                },
              },
              'metacpan_script' => 'score_version_numified',
            },
          },
          'path' => 'module',
          'score_mode' => 'max',
        },
      },
    },
  },
});
is $res->{hits}{hits}[0]{fields}{release}, "Perl-Version-1.013_03";
done_testing;
