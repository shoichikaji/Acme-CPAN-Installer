package App::cpm::Master;
use strict;
use warnings;

use App::cpm::CircularDependency;
use App::cpm::Distribution;
use App::cpm::Logger;
use App::cpm::Task;
use App::cpm::version;
use CPAN::DistnameInfo;
use IO::Handle;
use Module::Metadata;

sub new {
    my ($class, %option) = @_;
    my $self = bless {
        %option,
        installed_distributions => 0,
        tasks => +{},
        distributions => +{},
        _fail_resolve => +{},
        _fail_install => +{},
        _is_installed => +{},
    }, $class;
    if ($self->{target_perl}) {
        require Module::CoreList;
        if (!exists $Module::CoreList::version{$self->{target_perl}}) {
            die "Module::CoreList does not have target perl $self->{target_perl} entry, abort.\n";
        }
        if (!exists $Module::CoreList::version{$]}) {
            die "Module::CoreList does not have our perl $] entry, abort.\n";
        }
    }
    if (!$self->{global}) {
        if (eval { require Module::CoreList }) {
            if (!exists $Module::CoreList::version{$]}) {
                die "Module::CoreList does not have our perl $] entry, abort.\n";
            }
            $self->{_has_corelist} = 1;
        } else {
            my $msg = "You don't have Module::CoreList. "
                    . "The local-lib may result in incomplete self-contained directory.";
            App::cpm::Logger->log(result => "WARN", message => $msg);
        }
    }
    $self;
}

sub fail {
    my $self = shift;

    my @fail_resolve = sort keys %{$self->{_fail_resolve}};
    my @fail_install = sort keys %{$self->{_fail_install}};
    my @not_installed = grep { !$self->{_fail_install}{$_->distfile} && !$_->installed } $self->distributions;
    return if !@fail_resolve && !@fail_install && !@not_installed;

    my $detector = App::cpm::CircularDependency->new;
    for my $dist (@not_installed) {
        my $req = $dist->requirements([qw(configure build test runtime)])->as_array;
        $detector->add($dist->distfile, $dist->provides, $req);
    }
    $detector->finalize;

    my $detected = $detector->detect;
    for my $distfile (sort keys %$detected) {
        my $distvname = $self->distribution($distfile)->distvname;
        my @circular = @{$detected->{$distfile}};
        my $msg = join " -> ", map { $self->distribution($_)->distvname } @circular;
        local $self->{logger}{context} = $distvname;
        $self->{logger}->log("Detected circular dependencies $msg");
        $self->{logger}->log("Failed to install distribution");
    }
    for my $dist (sort { $a->distvname cmp $b->distvname } grep { !$detected->{$_->distfile} } @not_installed) {
        local $self->{logger}{context} = $dist->distvname;
        $self->{logger}->log("Failed to install distribution, "
                            ."because of installing some dependencies failed");
    }

    my @fail_install_name = map { CPAN::DistnameInfo->new($_)->distvname || $_ } @fail_install;
    my @not_installed_name = map { $_->distvname } @not_installed;
    if (@fail_resolve || @fail_install_name) {
        $self->{logger}->log("--");
        $self->{logger}->log(
            "Installation failed. "
            . "The direct cause of the failure comes from the following packages/distributions; "
            . "you may want to grep this log file by them:"
        );
        $self->{logger}->log(" * $_") for @fail_resolve, sort @fail_install_name;
    }
    { resolve => \@fail_resolve, install => [sort @fail_install_name, @not_installed_name] };
}

sub tasks { values %{shift->{tasks}} }

sub add_task {
    my ($self, %task) = @_;
    my $new = App::cpm::Task->new(%task);
    if (grep { $_->equals($new) } $self->tasks) {
        return 0;
    } else {
        $self->{tasks}{$new->uid} = $new;
        return 1;
    }
}

sub get_task {
    my $self = shift;
    if (my @task = grep { !$_->in_charge } $self->tasks) {
        return @task;
    }
    $self->_calculate_tasks;
    return unless $self->tasks;
    if (my @task = grep { !$_->in_charge } $self->tasks) {
        return @task;
    }
    return;
}

sub register_result {
    my ($self, $result) = @_;
    my ($task) = grep { $_->uid eq $result->{uid} } $self->tasks;
    die "Missing task that has uid=$result->{uid}" unless $task;

    %{$task} = %{$result}; # XXX

    my $logged = $self->info($task);
    my $method = "_register_@{[$task->{type}]}_result";
    $self->$method($task);
    $self->remove_task($task);
    $self->_show_progress if $logged && $self->{show_progress};

    return 1;
}

sub info {
    my ($self, $task) = @_;
    my $type = $task->type;
    return if !$App::cpm::Logger::VERBOSE && $type ne "install";
    my $name = $task->distvname;
    my ($message, $optional);
    if ($type eq "resolve") {
        $message = $task->{package};
        $message .= " -> $name" . ($task->{ref} ? "\@$task->{ref}" : "") if $task->{ok};
        $optional = "from $task->{from}" if $task->{ok} and $task->{from};
    } else {
        $message = $name;
        $optional = "using cache" if $type eq "fetch" and $task->{using_cache};
        $optional = "using prebuilt" if $task->{prebuilt};
    }
    my $elapsed = defined $task->{elapsed} ? sprintf "(%.3fsec) ", $task->{elapsed} : "";

    App::cpm::Logger->log(
        pid => $task->{pid},
        type => $type,
        result => $task->{ok} ? "DONE" : "FAIL",
        message => "$elapsed$message",
        optional => $optional,
    );
    return 1;
}

sub _show_progress {
    my $self = shift;
    my $all = keys %{$self->{distributions}};
    my $num = $self->installed_distributions;
    return if $App::cpm::Logger::QUIET;
    print STDERR "--- $num/$all ---";
    STDERR->flush; # this is needed at least with perl <= 5.24
}

sub remove_task {
    my ($self, $task) = @_;
    delete $self->{tasks}{$task->uid};
}

sub distributions { values %{shift->{distributions}} }

sub distribution {
    my ($self, $distfile) = @_;
    $self->{distributions}{$distfile};
}

sub _calculate_tasks {
    my $self = shift;

    my @distributions
        = grep { !$self->{_fail_install}{$_->distfile} } $self->distributions;

    if (my @dists = grep { $_->resolved && !$_->registered } @distributions) {
        for my $dist (@dists) {
            $dist->registered(1);
            $self->add_task(
                type => "fetch",
                distfile => $dist->{distfile},
                source => $dist->source,
                uri => $dist->uri,
                ref => $dist->ref,
            );
        }
    }

    if (my @dists = grep { $_->fetched && !$_->registered } @distributions) {
        for my $dist (@dists) {
            local $self->{logger}->{context} = $dist->distvname;
            my $dist_requirements = $dist->requirements('configure')->as_array;
            my ($is_satisfied, @need_resolve) = $self->is_satisfied($dist_requirements);
            if ($is_satisfied) {
                $dist->registered(1);
                $self->add_task(
                    type => "configure",
                    meta => $dist->meta,
                    directory => $dist->directory,
                    distfile => $dist->{distfile},
                    source => $dist->source,
                    uri => $dist->uri,
                    distvname => $dist->distvname,
                );
            } elsif (!defined $is_satisfied) {
                my ($req) = grep { $_->{package} eq "perl" } @$dist_requirements;
                my $msg = sprintf "%s requires perl %s, but you have only %s",
                    $dist->distvname, $req->{version_range}, $self->{target_perl} || $];
                $self->{logger}->log($msg);
                App::cpm::Logger->log(result => "FAIL", message => $msg);
                $self->{_fail_install}{$dist->distfile}++;
            } elsif (@need_resolve and !$dist->deps_registered) {
                $dist->deps_registered(1);
                my $msg = sprintf "Found configure dependencies: %s",
                    join(", ", map { sprintf "%s (%s)", $_->{package}, $_->{version_range} || 0 }  @need_resolve);
                $self->{logger}->log($msg);
                my $ok = $self->_register_resolve_task(@need_resolve);
                $self->{_fail_install}{$dist->distfile}++ unless $ok;
            }
        }
    }

    if (my @dists = grep { $_->configured && !$_->registered } @distributions) {
        for my $dist (@dists) {
            local $self->{logger}->{context} = $dist->distvname;

            my @phase = qw(build test runtime);
            push @phase, 'configure' if $dist->prebuilt;
            my $dist_requirements = $dist->requirements(\@phase)->as_array;
            my ($is_satisfied, @need_resolve) = $self->is_satisfied($dist_requirements);
            if ($is_satisfied) {
                $dist->registered(1);
                $self->add_task(
                    type => "install",
                    meta => $dist->meta,
                    distdata => $dist->distdata,
                    directory => $dist->directory,
                    distfile => $dist->{distfile},
                    uri => $dist->uri,
                    static_builder => $dist->static_builder,
                    prebuilt => $dist->prebuilt,
                );
            } elsif (!defined $is_satisfied) {
                my ($req) = grep { $_->{package} eq "perl" } @$dist_requirements;
                my $msg = sprintf "%s requires perl %s, but you have only %s",
                    $dist->distvname, $req->{version_range}, $self->{target_perl} || $];
                $self->{logger}->log($msg);
                App::cpm::Logger->log(result => "FAIL", message => $msg);
                $self->{_fail_install}{$dist->distfile}++;
            } elsif (@need_resolve and !$dist->deps_registered) {
                $dist->deps_registered(1);
                my $msg = sprintf "Found dependencies: %s",
                    join(", ", map { sprintf "%s (%s)", $_->{package}, $_->{version_range} || 0 }  @need_resolve);
                $self->{logger}->log($msg);
                my $ok = $self->_register_resolve_task(@need_resolve);
                $self->{_fail_install}{$dist->distfile}++ unless $ok;
            }
        }
    }
}

sub _register_resolve_task {
    my ($self, @package) = @_;
    my $ok = 1;
    for my $package (@package) {
        if ($self->{_fail_resolve}{$package->{package}}
            || $self->{_fail_install}{$package->{package}}
        ) {
            $ok = 0;
            next;
        }

        $self->add_task(
            type => "resolve",
            package => $package->{package},
            version_range => $package->{version_range},
        );
    }
    return $ok;
}

sub is_satisfied_perl_version {
    my ($self, $version_range) = @_;
    App::cpm::version->parse($self->{target_perl} || $])->satisfy($version_range);
}

sub is_installed {
    my ($self, $package, $version_range) = @_;
    my $wantarray = wantarray;
    if (exists $self->{_is_installed}{$package}) {
        if ($self->{_is_installed}{$package}->satisfy($version_range)) {
            return $wantarray ? (1, $self->{_is_installed}{$package}) : 1;
        }
    }
    my $info = Module::Metadata->new_from_module($package, inc => $self->{search_inc});
    return unless $info;

    if (!$self->{global} and $self->{_has_corelist} and $self->_in_core_inc($info->filename)) {
        # https://github.com/miyagawa/cpanminus/blob/7b574ede70cebce3709743ec1727f90d745e8580/Menlo-Legacy/lib/Menlo/CLI/Compat.pm#L1783-L1786
        # if found package in core inc,
        # but it does not list in CoreList,
        # we should treat it as not being installed
        return if !exists $Module::CoreList::version{$]}{$info->name};
    }
    my $current_version = $self->{_is_installed}{$package}
                        = App::cpm::version->parse($info->version);
    my $ok = $current_version->satisfy($version_range);
    $wantarray ? ($ok, $current_version) : $ok;
}

sub _in_core_inc {
    my ($self, $file) = @_;
    !!grep { $file =~ /^\Q$_/ } @{$self->{core_inc}};
}

sub is_core {
    my ($self, $package, $version_range) = @_;
    my $target_perl = $self->{target_perl};
    if (exists $Module::CoreList::version{$target_perl}{$package}) {
        if (!exists $Module::CoreList::version{$]}{$package}) {
            if (!$self->{_removed_core}{$package}++) {
                my $t = App::cpm::version->parse($target_perl)->normal;
                my $v = App::cpm::version->parse($])->normal;
                App::cpm::Logger->log(
                    result => "WARN",
                    message => "$package used to be core in $t, but not in $v, so will be installed",
                );
            }
            return;
        }
        return 1 unless $version_range;
        my $core_version = $Module::CoreList::version{$target_perl}{$package};
        return App::cpm::version->parse($core_version)->satisfy($version_range);
    }
    return;
}

# 0:     not satisfied, need wait for satisfying requirements
# 1:     satisfied, ready to install
# undef: not satisfied because of perl version
sub is_satisfied {
    my ($self, $requirements) = @_;
    my $is_satisfied = 1;
    my @need_resolve;
    my @distributions = $self->distributions;
    for my $req (@$requirements) {
        my ($package, $version_range) = @{$req}{qw(package version_range)};
        if ($package eq "perl") {
            $is_satisfied = undef if !$self->is_satisfied_perl_version($version_range);
            next;
        }
        next if $self->{target_perl} and $self->is_core($package, $version_range);
        next if $self->is_installed($package, $version_range);
        my ($resolved) = grep { $_->providing($package, $version_range) } @distributions;
        next if $resolved && $resolved->installed;

        $is_satisfied = 0 if defined $is_satisfied;
        if (!$resolved) {
            push @need_resolve, $req;
        }
    }
    return ($is_satisfied, @need_resolve);
}

sub add_distribution {
    my ($self, $distribution) = @_;
    my $distfile = $distribution->distfile;
    if (my $already = $self->{distributions}{$distfile}) {
        $already->overwrite_provide($_) for @{ $distribution->provides };
        return 0;
    } else {
        $self->{distributions}{$distfile} = $distribution;
        return 1;
    }
}

sub _register_resolve_result {
    my ($self, $task) = @_;
    if (!$task->is_success) {
        $self->{_fail_resolve}{$task->{package}}++;
        return;
    }

    local $self->{logger}{context} = $task->{package};
    if ($task->{distfile} and $task->{distfile} =~ m{/perl-5[^/]+$}) {
        my $message = "$task->{package} is a core module.";
        $self->{logger}->log($message);
        App::cpm::Logger->log(
            result => "DONE",
            type => "install",
            message => $message,
        );
        return;
    }

    if (!$task->{reinstall}) {
        my $want = $task->{version_range} || $task->{version};
        my ($ok, $local) = $self->is_installed($task->{package}, $want);
        if ($ok) {
            my $message = $task->{package} . (
                App::cpm::version->parse($task->{version}) != $local
                ? ", you already have $local"
                : " is up to date. ($local)"
            );
            $self->{logger}->log($message);
            App::cpm::Logger->log(
                result => "DONE",
                type => "install",
                message => $message,
            );
            return;
        }
    }

    my $provides = $task->{provides};
    if (!$provides or @$provides == 0) {
        my $version = App::cpm::version->parse($task->{version}) || 0;
        $provides = [{package => $task->{package}, version => $version}];
    }
    my $distribution = App::cpm::Distribution->new(
        source   => $task->{source},
        uri      => $task->{uri},
        provides => $provides,
        distfile => $task->{distfile},
        ref      => $task->{ref},
    );
    $self->add_distribution($distribution);
}

sub _register_fetch_result {
    my ($self, $task) = @_;
    if (!$task->is_success) {
        $self->{_fail_install}{$task->distfile}++;
        return;
    }
    my $distribution = $self->distribution($task->distfile);
    $distribution->directory($task->{directory});
    $distribution->meta($task->{meta});
    $distribution->provides($task->{provides});

    if ($task->{prebuilt}) {
        $distribution->configured(1);
        $distribution->requirements($_ => $task->{requirements}{$_}) for keys %{$task->{requirements}};
        $distribution->prebuilt(1);
        local $self->{logger}{context} = $distribution->distvname;
        my $msg = join ", ", map { sprintf "%s (%s)", $_->{package}, $_->{version} || 0 } @{$distribution->provides};
        $self->{logger}->log("Distribution provides: $msg");
    } else {
        $distribution->fetched(1);
        $distribution->requirements($_ => $task->{requirements}{$_}) for keys %{$task->{requirements}};
    }
    return 1;
}

sub _register_configure_result {
    my ($self, $task) = @_;
    if (!$task->is_success) {
        $self->{_fail_install}{$task->distfile}++;
        return;
    }
    my $distribution = $self->distribution($task->distfile);
    $distribution->configured(1);
    $distribution->requirements($_ => $task->{requirements}{$_}) for keys %{$task->{requirements}};
    $distribution->static_builder($task->{static_builder});
    $distribution->distdata($task->{distdata});

    # After configuring, the final "provides" is fixed.
    # So we need to re-define "provides" here
    my $p = $task->{distdata}{provides};
    my @provide = map +{ package => $_, version => $p->{$_}{version} }, sort keys %$p;
    $distribution->provides(\@provide);
    local $self->{logger}{context} = $distribution->distvname;
    my $msg = join ", ", map { sprintf "%s (%s)", $_->{package}, $_->{version} || 0 } @{$distribution->provides};
    $self->{logger}->log("Distribution provides: $msg");

    return 1;
}

sub _register_install_result {
    my ($self, $task) = @_;
    if (!$task->is_success) {
        $self->{_fail_install}{$task->distfile}++;
        return;
    }
    my $distribution = $self->distribution($task->distfile);
    $distribution->installed(1);
    $self->{installed_distributions}++;
    return 1;
}

sub installed_distributions {
    shift->{installed_distributions};
}

1;
