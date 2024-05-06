requires 'Cpanel::JSON::XS';
requires 'JSON::MaybeXS';
requires 'Plack::Builder';
requires 'Plack::Request';
requires 'HTTP::Tiny';
requires 'CPAN::DistnameInfo';
requires 'URI::Escape';
requires 'Moo';
requires 'IO::Socket::SSL' => '1.42';
requires 'Plack::Middleware::SimpleLogger';
requires 'WWW::Form::UrlEncoded';
requires 'HTTP::Request::Common';

on test => sub {
  requires 'Plack::Test';
  requires 'LWP::Protocol::PSGI' => '0.10';
};
