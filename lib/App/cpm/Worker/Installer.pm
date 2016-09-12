package App::cpm::Worker::Installer;
use strict;
use warnings;
use utf8;

use CPAN::DistnameInfo;
use CPAN::Meta;
use File::Basename 'basename';
use File::Path qw(mkpath rmtree);
use File::Spec;
use File::pushd 'pushd';
use File::Copy ();
use File::Copy::Recursive ();
use JSON::PP qw(encode_json decode_json);
use Menlo::CLI::Compat;

sub work {
    my ($self, $job) = @_;
    my $type = $job->{type} || "(undef)";
    if ($type eq "fetch") {
        my ($directory, $meta, $configure_requirements, $provides)
            = $self->fetch($job->{distfile});
        if ($configure_requirements) {
            return +{
                ok => 1,
                directory => $directory,
                meta => $meta,
                configure_requirements => $configure_requirements,
                provides => $provides,
            };
        }
    } elsif ($type eq "configure") {
        my ($distdata, $requirements)
            = $self->configure(
                $job->{directory},
                $job->{distfile},
                $job->{meta},
                $job->{with_develop},
                $job->{features},
            );
        if ($requirements) {
            return +{
                ok => 1,
                distdata => $distdata,
                requirements => $requirements,
            };
        }
    } elsif ($type eq "install") {
        my $ok = $self->install($job->{directory}, $job->{distdata});
        rmtree $job->{directory} if $ok; # XXX Carmel!!!
        return { ok => $ok };
    } else {
        die "Unknown type: $type\n";
    }
    return { ok => 0 };
}

sub new {
    my ($class, %option) = @_;
    my $menlo_base = (delete $option{menlo_base}) || "$ENV{HOME}/.perl-cpm/work";
    my $menlo_build_log = (delete $option{menlo_build_log}) || "$menlo_base/build.log";
    my $menlo_cache = (delete $option{menlo_cache}) || "$ENV{HOME}/.perl-cpm/cache";
    mkpath $menlo_base unless -d $menlo_base;
    $option{mirror} = [$option{mirror}] if ref $option{mirror} ne 'ARRAY';

    my $menlo = Menlo::CLI::Compat->new(
        base => $menlo_base,
        save_dists => $menlo_cache,
        log  => $menlo_build_log,
        quiet => 1,
        pod2man => undef,
        # force using HTTP::Tiny
        try_wget => 0,
        try_curl => 0,
        try_lwp  => 0,
        notest   => $option{notest},
        sudo     => $option{sudo},
    );
    if (my $local_lib = delete $option{local_lib}) {
        $menlo->{self_contained} = 1;
        $menlo->setup_local_lib($menlo->maybe_abs($local_lib));
    }
    $menlo->init_tools;
    bless { %option, menlo => $menlo }, $class;
}

sub menlo { shift->{menlo} }

sub fetch {
    my ($self, $distfile) = @_;
    my $guard = pushd;

    my $dir;
    if (-d $distfile) {
        my $dest = File::Spec->catdir(
            $self->menlo->{base}, basename($distfile) . "." . time
        );
        rmtree $dest if -d $dest;
        File::Copy::Recursive::dircopy($distfile, $dest);
        $dir = $dest;
    } elsif ($distfile =~ /(?:^git:|\.git(?:@.+)?$)/) {
        my $result = $self->menlo->git_uri($distfile)
            or return;
        $dir = $result->{dir};
    } else {
        chdir $self->menlo->{base};
        my $basename = basename($distfile);
        my ($old) = $basename =~ /^(.+)\.(?:tar\.gz|zip|tar\.bz2|tgz)$/;
        rmtree $old if $old && -d $old;

        my $cache = File::Spec->catfile($self->menlo->{save_dists}, "authors/id/$distfile");
        if (-f $cache) {
            File::Copy::copy($cache, $basename) or return;
            $dir = $self->menlo->unpack($basename) or return;
        } else {
            my @uris = map { "$_/authors/id/$distfile" } @{ $self->{mirror} };
            my $dist = { uris => \@uris, pathname => $distfile };
            $dir = $self->menlo->fetch_module($dist) or return;
        }
        $dir = File::Spec->catdir($self->menlo->{base}, $dir);
    }
    chdir $dir or die;
    my ($meta, $configure_requirements, $provides)
        = $self->_get_configure_requirements($distfile);
    return ($dir, $meta, $configure_requirements, $provides);
}

sub _get_configure_requirements {
    my ($self, $distfile) = @_;
    my $meta;
    if (my ($file) = grep -f, qw(META.json META.yml)) {
        $meta = eval { CPAN::Meta->load_file($file) };
    }

    unless ($meta) {
        my $d = CPAN::DistnameInfo->new($distfile);
        $meta = CPAN::Meta->new({name => $d->dist, version => $d->version});
    }

    my $requirements = $self->_extract_requirements($meta, [qw(configure)]);
    my $p = $self->menlo->extract_packages($meta, ".");
    my $provides = [map +{
        package => $_,
        version => $p->{$_}{version} || undef,
    }, sort keys %$p];

    if (!@$requirements && -f "Build.PL") {
        push @$requirements, {
            package => "Module::Build", version => "0.38",
            phase => "configure", type => "requires",
        };
    }
    return ($meta ? $meta->as_struct : +{}, $requirements, $provides);
}


sub _extract_requirements {
    my ($self, $meta, $phases, $allowed_features) = @_;
    $phases = [$phases] unless ref $phases;

    my @effective_features;
    if ($allowed_features->{__all}) {
        @effective_features = map $_->identifier, $meta->features;
    }

    my $hash = $meta->effective_prereqs(\@effective_features)->as_string_hash;
    my @requirements;
    for my $phase (@$phases) {
        my $reqs = ($hash->{$phase} || +{})->{requires} || +{};
        for my $package (sort keys %$reqs) {
            push @requirements, {
                package => $package, version => $reqs->{$package},
                phase => $phase, type => "requires",
            };
        }
    }
    \@requirements;
}

sub configure {
    my ($self, $dir, $distfile, $meta, $with_develop, $features) = @_;
    my $guard = pushd $dir;
    my $menlo = $self->menlo;
    if (-f 'Build.PL') {
        $menlo->configure([ $menlo->{perl}, 'Build.PL' ], 1);
        return unless -f 'Build';
    } elsif (-f 'Makefile.PL') {
        $menlo->configure([ $menlo->{perl}, 'Makefile.PL' ], 1); # XXX depth == 1?
        return unless -f 'Makefile';
    }
    my $distdata = $self->_build_distdata($distfile, $meta);
    my $requirements = [];
    my $phase = $self->{notest} ? [qw(build runtime)] : [qw(build test runtime)];
    push @$phase, 'develop' if $with_develop;

    if (my ($file) = grep -f, qw(MYMETA.json MYMETA.yml)) {
        my $mymeta = CPAN::Meta->load_file($file);
        $requirements = $self->_extract_requirements($mymeta, $phase, $features);
    }
    return ($distdata, $requirements);
}

sub _build_distdata {
    my ($self, $distfile, $meta) = @_;

    my $menlo = $self->menlo;
    my $fake_state = { configured_ok => 1, use_module_build => -f "Build" };
    my $module_name = $menlo->find_module_name($fake_state) || $meta->{name};
    $module_name =~ s/-/::/g;

    # XXX: if $distfile is git url, CPAN::DistnameInfo->distvname returns undef.
    # Then menlo->save_meta does nothing.
    my $distvname = CPAN::DistnameInfo->new($distfile)->distvname;
    my $provides = $meta->{provides} || $menlo->extract_packages($meta, ".");
    +{
        distvname => $distvname,
        pathname => $distfile,
        provides => $provides,
        version => $meta->{version} || 0,
        source => "cpan",
        module_name => $module_name,
    };
}

sub install {
    my ($self, $dir, $distdata) = @_;

    my $guard = pushd $dir;
    my $menlo = $self->menlo;

    my $installed;
    if (-f 'Build') {
        $menlo->build([ $menlo->{perl}, "./Build" ], )
        && $menlo->test([ $menlo->{perl}, "./Build", "test" ], )
        && $menlo->install([ $menlo->{perl}, "./Build", "install" ], [])
        && $installed++;
    } else {
        $menlo->build([ $menlo->{make} ], )
        && $menlo->test([ $menlo->{make}, "test" ], )
        && $menlo->install([ $menlo->{make}, "install" ], [])
        && $installed++;
    }

    if ($installed && $distdata) {
        $menlo->save_meta(
            $distdata->{module_name},
            $distdata,
            $distdata->{module_name},
        );
    }
    return $installed;
}

1;
