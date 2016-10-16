use strict;
use warnings;
use utf8;
use Test::More;
use App::cpm::Worker::Installer;
use Config;
use File::Temp 'tempdir';

my $tempdir = tempdir CLEANUP => 1;
my $installer = App::cpm::Worker::Installer->new(
    local_lib => $tempdir,
);

my $mirror = "http://www.cpan.org";
my $distfile = "S/SK/SKAJI/Distribution-Metadata-0.05.tar.gz";
my $job = { source => "cpan", uri => ["$mirror/authors/id/$distfile"], distfile => $distfile };
my ($dir, $meta, $configure_requirements) = $installer->fetch($job);

like $dir, qr{^/.*Distribution-Metadata-0\.05$}; # abs
ok scalar(keys %$meta);
is_deeply $configure_requirements, [
  {
    package => "ExtUtils::MakeMaker",
    phase   => "configure",
    type    => "requires",
    version => 0,
  },
];

my ($distdata, $requirements) = $installer->configure({
    directory => $dir,
    distfile => $distfile,
    meta => $meta,
    source => "cpan",
});

is $distdata->{distvname}, "Distribution-Metadata-0.05";

is_deeply $requirements->[-1], {
    package => "perl",
    phase   => "runtime",
    type    => "requires",
    version => "5.008001",
};

done_testing;
