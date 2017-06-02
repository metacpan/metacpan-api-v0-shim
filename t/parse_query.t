use strict;
use warnings;
use Test::More;
use MetaCPAN::V0Shim;

my $shim = MetaCPAN::V0Shim->new;

is_deeply $shim->cpanm_module_query_to_params({
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
                      { 'term' => { 'module.authorized' => 1 } },
                      { 'term' => { 'module.indexed' => 1 } },
                      { 'term' => { 'module.name' => 'Perl::Version' } },
                      { 'term' => { 'module.version' => '1.013030' } },
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
}), {
  module => 'Perl::Version',
  version => '== 1.013030',
}, 'explicit version';

is_deeply $shim->cpanm_module_query_to_params({
  'fields' => [
    'date',
    'release',
    'author',
    'module',
    'status',
  ],
  'query' => {
    'filtered' => {
      'filter' => {
        'and' => [
          { 'not' => { 'term' => { 'status' => 'backpan' } } },
          { 'term' => { 'maturity' => 'released' } },
        ]
      },
      'query' => {
        'nested' => {
          'path' => 'module',
          'query' => {
            'custom_score' => {
              'metacpan_script' => 'score_version_numified',
              'query' => {
                'constant_score' => {
                  'filter' => {
                    'and' => [
                      { 'term' => { 'module.authorized' => 1 } },
                      { 'term' => { 'module.indexed' => 1 } },
                      { 'term' => { 'module.name' => 'DBD::XBase' } },
                      { 'range' => { 'module.version_numified' => { 'gte' => '0.020', 'lt' => '0.234' } } },
                      { 'not' => { 'or' => [ { 'term' => { 'module.version_numified' => '0.030' } } ] } },
                    ],
                  },
                },
              },
            },
          },
          'score_mode' => 'max'
        },
      },
    },
  },
}), {
  module => 'DBD::XBase',
  version => '>= 0.020, != 0.030, < 0.234',
}, 'version range';


is_deeply $shim->cpanm_module_query_to_params({
  'fields' => [
    'date',
    'release',
    'author',
    'module',
    'status',
  ],
  'query' => {
    'filtered' => {
      'filter' => {
        'and' => [
          { 'not' => { 'term' => { 'status' => 'backpan' } } },
        ],
      },
      'query' => {
        'nested' => {
          'path' => 'module',
          'query' => {
            'custom_score' => {
              'metacpan_script' => 'score_version_numified',
              'query' => {
                'constant_score' => {
                  'filter' => {
                    'and' => [
                      { 'term' => { 'module.authorized' => 1 } },
                      { 'term' => { 'module.indexed' => 1 } },
                      { 'term' => { 'module.name' => 'DBD::XBase' } },
                      { 'range' => { 'module.version_numified' => { 'gte' => '0.234' } } },
                    ],
                  },
                },
              },
            },
          },
          'score_mode' => 'max'
        },
      },
    },
  },
}), {
  module => 'DBD::XBase',
  version => '0.234',
  dev => 1,
}, 'dev release';

done_testing;
