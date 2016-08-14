package App::cpm;
use 5.008_005;
use strict;
use warnings;
use App::cpm::Master;
use App::cpm::Worker;
use App::cpm::Logger;
use App::cpm::version;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use Pod::Usage ();
use Cwd 'abs_path';
use Config;

our $VERSION = '0.118';

sub new {
    my ($class, %option) = @_;
    bless {
        workers => 5,
        snapshot => "cpanfile.snapshot",
        cpanfile => "cpanfile",
        local_lib => "local",
        cpanmetadb => "http://cpanmetadb.plackperl.org/v1.0/package",
        mirror => ["http://www.cpan.org"],
        target_perl => $],
        %option
    }, $class;
}

sub parse_options {
    my $self = shift;
    local @ARGV = @_;
    $self->{notest} = 1;
    my @mirror;
    GetOptions
        "L|local-lib-contained=s" => \($self->{local_lib}),
        "V|version" => sub { $self->cmd_version },
        "color!" => \($self->{color}),
        "g|global" => \($self->{global}),
        "h|help" => sub { $self->cmd_help },
        "mirror=s@" => \@mirror,
        "v|verbose" => \($self->{verbose}),
        "w|workers=i" => \($self->{workers}),
        "target-perl=s" => \my $target_perl,
        "test!" => sub { $self->{notest} = $_[1] ? 0 : 1 },
        "cpanfile=s" => \($self->{cpanfile}),
        "snapshot=s" => \($self->{snapshot}),
    or exit 1;

    $self->{local_lib} = abs_path $self->{local_lib} unless $self->{global};
    $self->{mirror} = \@mirror if @mirror;
    $_ =~ s{/$}{} for @{$self->{mirror}};
    $self->{color} = 1 if !defined $self->{color} && -t STDOUT;
    if ($target_perl) {
        # 5.8 is interpreted as 5.800, fix it
        $target_perl = "v$target_perl" if $target_perl =~ /^5\.[1-9]\d*$/;
        $self->{target_perl} = App::cpm::version->parse($target_perl)->numify;
        if ($self->{target_perl} > $]) {
            die "--target-perl must be lower than your perl version $]\n";
        }
    }

    $App::cpm::Logger::COLOR = 1 if $self->{color};
    $App::cpm::Logger::VERBOSE = 1 if $self->{verbose};
    @ARGV;
}

sub _core_inc {
    my $self = shift;
    (
        (!$self->{exclude_vendor} ? grep {$_} @Config{qw(vendorarch vendorlibexp)} : ()),
        @Config{qw(archlibexp privlibexp)},
    );
}

sub _user_inc {
    my $self = shift;
    if ($self->{global}) {
        my %core = map { $_ => 1 } $self->_core_inc;
        return grep { !$core{$_} } @INC;
    }

    my $base = $self->{local_lib};
    require local::lib;
    (
        local::lib->resolve_path(local::lib->install_base_arch_path($base)),
        local::lib->resolve_path(local::lib->install_base_perl_path($base)),
    );
}

sub run {
    my ($self, @argv) = @_;
    my $cmd = shift @argv or die "Need subcommand, try `cpm --help`\n";
    $cmd = "help"    if $cmd =~ /^(-h|--help)$/;
    $cmd = "version" if $cmd =~ /^(-V|--version)$/;
    if (my $sub = $self->can("cmd_$cmd")) {
        @argv = $self->parse_options(@argv) unless $cmd eq "exec";
        return $self->$sub(@argv);
    } else {
        my $message = $cmd =~ /^-/ ? "Missing subcommand" : "Unknown subcommand '$cmd'";
        die "$message, try `cpm --help`\n";
    }
}

sub cmd_help {
    Pod::Usage::pod2usage(0);
}

sub cmd_version {
    my $class = ref $_[0] || $_[0];
    printf "%s %s\n", $class, $class->VERSION;
    exit 0;
}

sub cmd_exec {
    my ($self, @argv) = @_;
    my $local_lib = abs_path $self->{local_lib};
    if (-d "$local_lib/lib/perl5") {
        $ENV{PERL5LIB} = "$local_lib/lib/perl5"
                       . ($ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : "");
    }
    if (-d "$local_lib/bin") {
        $ENV{PATH} = "$local_lib/bin:$ENV{PATH}";
    }
    exec @argv;
    exit 255;
}

sub cmd_install {
    my ($self, @argv) = @_;
    die "Need arguments or cpanfile.\n" if !@argv && !-f $self->{cpanfile};

    my $master = App::cpm::Master->new(
        core_inc => [$self->_core_inc],
        user_inc => [$self->_user_inc],
        target_perl => $self->{target_perl},
    );

    my @package;
    for my $arg (@argv) {
        if (-d $arg or $arg =~ /(?:^git:|\.git(?:@.+)?$)/) {
            $arg = abs_path $arg if -d $arg;
            my $dist = App::cpm::Distribution->new(distfile => $arg, provides => []);
            $master->add_distribution($dist);
        } else {
            push @package, {package => $arg, version => 0};
        }
    }

    if (!@argv) {
        warn "Loading modules from $self->{cpanfile}...\n";
        my $requirements = $self->load_cpanfile($self->{cpanfile});
        my ($is_satisfied, @need_resolve) = $master->is_satisfied($requirements);
        if ($is_satisfied) {
            warn "All requirements are satisfied.\n";
            return 0; # exit 0
        } elsif (!defined $is_satisfied) {
            my ($req) = grep { $_->{package} eq "perl" } @$requirements;
            die sprintf "%s requires perl %s\n", $self->{cpanfile}, $req->{version};
        } else {
            @package = @need_resolve;
        }

        if (-f $self->{snapshot}) {
            if (!eval { require Carton::Snapshot }) {
                die "To load $self->{snapshot}, you need to install Carton::Snapshot.\n";
            }
            warn "Loading distributions from $self->{snapshot}...\n";
            if (!grep { /backpan/ } @{$self->{mirror}}) {
                push @{$self->{mirror}}, "http://backpan.perl.org/"; # XXX
            }
        }
    }

    $master->add_job(
        type => "resolve",
        package => $_->{package},
        version => $_->{version} || 0
    ) for @package;

    my $menlo_base = "$ENV{HOME}/.perl-cpm/work";
    my $menlo_cache = "$ENV{HOME}/.perl-cpm/cache";
    my $menlo_build_log = "$ENV{HOME}/.perl-cpm/build.@{[time]}.log";
    my $cb = sub {
        my ($read_fh, $write_fh) = @_;
        my $worker = App::cpm::Worker->new(
            verbose => $self->{verbose},
            cpanmetadb => $self->{cpanmetadb},
            mirror => $self->{mirror},
            read_fh => $read_fh, write_fh => $write_fh,
            ($self->{global} ? () : (local_lib => $self->{local_lib})),
            menlo_base => $menlo_base, menlo_build_log => $menlo_build_log,
            menlo_cache => $menlo_cache,
            notest => $self->{notest},
            (!@argv && -f $self->{snapshot} ? (snapshot => $self->{snapshot}) : ()),
        );
        $worker->run_loop;
    };

    $master->spawn_worker($cb) for 1 .. $self->{workers};
    MAIN_LOOP:
    while (1) {
        for my $worker ($master->ready_workers) {
            $master->register_result($worker->result) if $worker->has_result;
            my $job = $master->get_job or last MAIN_LOOP;
            $worker->work($job);
        }
    }
    $master->shutdown_workers;

    if (my $fail = $master->fail) {
        local $App::cpm::Logger::VERBOSE = 0;
        for my $type (qw(install resolve)) {
            App::cpm::Logger->log(
                result => "FAIL",
                type => $type,
                message => $_,
            ) for @{$fail->{$type}};
        }
    }
    my $num = $master->installed_distributions;
    warn "$num distribution@{[$num > 1 ? 's' : '']} installed.\n";
    return $master->fail ? 1 : 0;
}

sub load_cpanfile {
    my ($self, $file) = @_;
    require Module::CPANfile;
    my $cpanfile = Module::CPANfile->load($file);
    my @package;
    for my $package ($cpanfile->merged_requirements->required_modules) {
        my $version =$cpanfile->prereq_for_module($package)->requirement->version;
        push @package, { package => $package, version => $version };
    }
    \@package;
}

sub load_snapshot {
    my ($self, $file) = @_;
    eval { require Carton::Snapshot };
    if ($@) {
        die "To load $file, you need to install Carton::Snapshot first.\n";
    }
    my $snapshot = Carton::Snapshot->new(path => $file);
    $snapshot->load;
    my @distributions;
    for my $dist ($snapshot->distributions) {
        my @provides = map {
            my $package = $_;
            my $version = $dist->provides->{$_}{version};
            $version = undef if $version eq "undef";
            +{ package => $package, version => $version };
        } sort keys %{$dist->provides};

        push @distributions, App::cpm::Distribution->new(
            distfile => $dist->distfile,
            provides => \@provides,
        );
    }
    @distributions;
}

1;
__END__

=encoding utf-8

=head1 NAME

App::cpm - a fast CPAN module installer

=head1 SYNOPSIS

  > cpm install Module

=head1 DESCRIPTION

=for html
<a href="https://raw.githubusercontent.com/skaji/cpm/master/xt/demo.gif"><img src="https://raw.githubusercontent.com/skaji/cpm/master/xt/demo.gif" alt="demo" style="max-width:100%;"></a>

B<THIS IS EXPERIMENTAL.>

cpm is a fast CPAN module installer, which uses L<Menlo> in parallel.

=head1 MOTIVATION

Why do we need a new CPAN client?

I used L<cpanm> a lot, and it's totally awesome.

But if your Perl project has hundreds of CPAN module dependencies,
then it takes quite a lot of time to install them.

So my motivation is simple: I want to install CPAN modules as fast as possible.

=head2 HOW FAST?

Just an example:

  > time cpanm -nq -Lextlib Plack
  real 0m47.705s

  > time cpm install Plack
  real 0m16.629s

This shows cpm is 3x faster than cpanm.

=head1 ROADMAP

If you all find cpm useful,
then cpm should be merged into cpanm 2.0. How exciting!

To merge cpm into cpanm, there are several TODOs:

=over 4

=item * Win32? - support platforms that do not have fork(2) system call

=item * Logging? - the parallel feature makes log really messy

=back

Your feedback is highly appreciated.

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Shoichi Kaji E<lt>skaji@cpan.orgE<gt>

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO


L<Perl Advent Calendar 2015|http://www.perladvent.org/2015/2015-12-02.html>

L<App::cpanminus>

L<Menlo>

L<Carton>

=cut
