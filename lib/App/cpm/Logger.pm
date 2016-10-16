package App::cpm::Logger;
use strict;
use warnings;
use utf8;
use List::Util 'max';

our $COLOR;
our $VERBOSE;

my %color = (
    resolve => 33,
    fetch => 34,
    configure => 35,
    install => 36,
    FAIL => 31,
    DONE => 32,
    WARN => 33,
);

sub new {
    my $class = shift;
    bless {@_}, $class;
}

sub log {
    my ($self, %option) = @_;
    my $type = $option{type} || "";
    my $message = $option{message};
    chomp $message;
    my $optional = $option{optional} ? "($option{optional})" : "";
    my $result = $option{result};
    my $is_color = ref $self ? $self->{color} : $COLOR;
    my $verbose = ref $self ? $self->{verbose} : $VERBOSE;

    if ($is_color) {
        $type = "\e[$color{$type}m$type\e[m" if $type && $color{$type};
        $result = "\e[$color{$result}m$result\e[m" if $result && $color{$result};
        $optional = "\e[1;37m$optional\e[m" if $optional;
    }

    if ($verbose) {
        # type -> 5 + 9 + 3
        $type = $is_color && $type ? sprintf("%-17s", $type) : sprintf("%-9s", $type || "");
        warn sprintf "%d %s %s %s%s\n", $$, $result, $type, $message, $optional ? " $optional" : "";
    } else {
        warn join(" ", $result, $type ? $type : (), $message) . "\n";
    }
}

1;
