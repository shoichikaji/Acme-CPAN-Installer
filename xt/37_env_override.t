use strict;
use warnings;
use Test::More;
use Capture::Tiny 'capture';
use App::cpm::CLI;

$ENV{PERL_CPM_MIRROR} = 'https://pan.not-metacpan.org';
my $cli = App::cpm::CLI->new;
is $cli->{_default_mirror}, 'https://pan.not-metacpan.org', 'default mirror overridden from ENV';

$cli = App::cpm::CLI->new();
my ($out, $err, $exit) = capture {
	$cli->run("--version", '--mirror', 'https://other-pan.not-metacpan.org');
};
is $cli->{mirror}, 'https://other-pan.not-metacpan.org/', 'mirror option always has precedence over ENV (and is normalized)';

done_testing();
