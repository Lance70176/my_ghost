#!/usr/bin/perl
# Merge MyGhost's status hooks into a Codex hooks.json, keeping every other
# hook. Usage: merge-codex-hooks.pl <hooks.json> <path to myghost-status>
use strict;
use warnings;
use JSON::PP;

my ($file, $bin) = @ARGV;
die "usage: $0 hooks.json myghost-status\n" unless $bin;

# Codex hook event => arguments for myghost-status.
my %events = (
    SessionStart      => 'clear codex',
    UserPromptSubmit  => 'working codex',
    PreToolUse        => 'working codex',
    PostToolUse       => 'working codex',
    PermissionRequest => 'blocked codex permission',
    Stop              => 'done codex',
    SessionEnd        => 'clear codex',
);

my $json = JSON::PP->new->utf8->pretty->canonical;
my $doc = {};
if (-s $file) {
    open(my $in, '<', $file) or die "$file: $!\n";
    local $/;
    $doc = $json->decode(<$in>);
}
my $hooks = $doc->{hooks} ||= {};

(my $quoted = $bin) =~ s/'/'\\''/g;
for my $event (sort keys %events) {
    my @groups = grep {
        !grep { ($_->{command} // '') =~ /myghost-status/ } @{ $_->{hooks} || [] }
    } @{ $hooks->{$event} || [] };
    push @groups, {
        hooks => [{ type => 'command', command => "'$quoted' $events{$event}", timeout => 5 }],
    };
    $hooks->{$event} = \@groups;
}

my $tmp = "$file.tmp-myghost";
open(my $out, '>', $tmp) or die "$tmp: $!\n";
print $out $json->encode($doc);
close $out or die "$tmp: $!\n";
rename $tmp, $file or die "$file: $!\n";
