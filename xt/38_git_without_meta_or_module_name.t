use strict;
use warnings;
use Test::More;
use lib "xt/lib";
use CLI;

subtest git_without_meta_or_module_name => sub {
    my $r = cpm_install "-v", 'https://github.com/ap/Async.git@v0.14';
    is $r->exit, 0;
    note $r->err;
};

subtest fail => sub {
    local $ENV{GIT_TERMINAL_PROMPT} = 0;
    my $r = cpm_install "-v", 'https://github.com/ap/Async.git@xxxxx';
    isnt $r->exit, 0;
    note $r->err;
};

done_testing;
