use strict;
use warnings;
use Test::More;
use lib "xt/lib";
use CLI;

subtest remote_tar_without_meta_or_module_name => sub {
    my $r = cpm_install "-v", "https://cpan.metacpan.org/authors/id/G/GC/GCAMPBELL/Data-Diff-0.01.tar.gz";
    is $r->exit, 0;
    note $r->err;
};

subtest fail => sub {
    my $r = cpm_install "-v", "https://cpan.metacpan.org/authors/id/G/GC/GCAMPBELL/Data-Diff-0.01.xxx";
    isnt $r->exit, 0;
    note $r->err;
};

done_testing;
