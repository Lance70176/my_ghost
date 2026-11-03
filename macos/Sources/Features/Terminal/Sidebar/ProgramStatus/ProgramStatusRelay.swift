import Foundation

/// The Perl relay that `pipe-pane` runs for every MyGhost tmux pane; see
/// ProgramStatusMonitor. It is written next to tmux.conf at startup so the
/// panes' relays (which outlive the app, in the tmux server) find it there.
enum ProgramStatusRelay {
    static var path: String {
        ScreenSessionManager.shared.supportDirectoryURL
            .appendingPathComponent("myghost-psp.pl").path
    }

    /// Write the script unless it is already current.
    static func install() {
        let url = URL(fileURLWithPath: path)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == script { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? script.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // Kept in step with the spec: Program Status Protocol draft 0.4
    // (superlogical.com/rex/docs/build/program-status).
    static let script = #"""
#!/usr/bin/perl
# MyGhost relay for the Program Status Protocol (OSC 7501, draft 0.4).
#
# tmux drops OSC sequences it does not know, so a program's status report
# never reaches MyGhost. tmux `pipe-pane -O` hands this script the pane's raw
# output instead; it keeps the pane's records as the spec says and stores a
# summary in the pane option @myghost_psp, which MyGhost polls.
#
# Usage: myghost-psp.pl <tmux binary> <tmux socket> <pane id>
use strict;
use warnings;
use MIME::Base64 ();
use Time::HiRes ();

my ($TMUX, $SOCK, $PANE) = @ARGV;
die "usage: $0 tmux socket pane\n" unless defined $PANE;
binmode STDIN;

my %STATES = map { $_ => 1 } qw(idle working done blocked error clear);
my %KINDS = map { $_ => 1 } qw(permission question auth);
my %RANK = (blocked => 5, error => 4, working => 3, done => 2, idle => 1);
my $MAX_RECORDS = 256;
my $PUSH_GAP = 0.2;    # seconds between tmux writes while reports stream in

my %rec;               # id ('' = root) => record
my $tick = 0;
my $seq = 0;
my $dirty = 1;         # start by clearing what an earlier relay left behind
my $last_push = 0;
my $buf = '';

sub valid_id {
    my ($id) = @_;
    return 0 if length($id) > 128;
    my @seg = split m{/}, $id, -1;
    return 0 if @seg < 1 || @seg > 8;
    for (@seg) { return 0 unless /\A[A-Za-z0-9_.+-]{1,32}\z/ }
    return 1;
}

# Decode a base64 text field; undef (with $bad set) when the report must go.
sub text_field {
    my ($v, $enc_max, $dec_max, $bad) = @_;
    if (length($v) > $enc_max) { $$bad = 1; return }
    (my $core = $v) =~ s/=+\z//;
    if ($core =~ m{[^A-Za-z0-9+/]} || length($core) % 4 == 1) { $$bad = 1; return }
    my $bytes = MIME::Base64::decode_base64($v);
    if (length($bytes) > $dec_max) { $$bad = 1; return }
    my $text = $bytes;
    if (!utf8::decode($text)) { $$bad = 1; return }
    if ($text =~ /[\x00-\x1f\x7f-\x9f]/) { $$bad = 1; return }
    return $v;
}

sub report {
    my ($body) = @_;
    # A support query: the reply would have to reach the program through
    # tmux, which answers the CSI c that follows a query first anyway.
    return if $body =~ /\A\s*\?\s*(?::|\z)/;

    my %kv;
    for my $pair (split /:/, $body, -1) {
        next unless $pair =~ /\A\s*([^=]*?)\s*=\s*(.*?)\s*\z/s;
        my ($k, $v) = ($1, $2);
        next unless $k =~ /\A[a-z]+\z/;
        return if length($k) > 16;
        next unless $v =~ m{\A[A-Za-z0-9_.,+/=-]*\z};
        $kv{$k} = $v;
    }

    my $state = $kv{state};
    return unless defined $state && $STATES{$state};

    my $id = '';
    if (exists $kv{id}) {
        return unless valid_id($kv{id});
        $id = $kv{id};
    }

    if ($state eq 'clear') {
        if (exists $kv{id}) {
            delete $rec{$_} for grep { $_ eq $id || index($_, "$id/") == 0 } keys %rec;
        } else {
            %rec = ();
        }
        $dirty = 1;
        return;
    }

    my %r = (state => $state, t => ++$tick);
    if (defined(my $app = $kv{app})) {
        return if length($app) > 32;
        $r{app} = $app if $app =~ /\A[A-Za-z0-9_.+-]{1,32}\z/;
    }
    if (($state eq 'working' || $state eq 'blocked') && defined $kv{progress}
        && $kv{progress} =~ /\A\d{1,3}\z/ && $kv{progress} <= 100) {
        $r{progress} = $kv{progress} + 0;
    }
    if ($state eq 'blocked' && defined $kv{kind} && $KINDS{$kv{kind}}) {
        $r{kind} = $kv{kind};
    }
    my $bad = 0;
    $r{title} = text_field($kv{title}, 256, 192, \$bad) if defined $kv{title};
    $r{msg} = text_field($kv{msg}, 2732, 2048, \$bad) if defined $kv{msg};
    return if $bad;
    delete $r{$_} for grep { !defined $r{$_} } keys %r;

    $rec{$id} = \%r;
    if (keys(%rec) > $MAX_RECORDS) {
        my ($oldest) = sort { $rec{$a}{t} <=> $rec{$b}{t} } keys %rec;
        delete $rec{$oldest};
    }
    $dirty = 1;
}

# A new shell prompt (OSC 133;A) ends whatever was running or waiting.
sub prompt {
    my @gone = grep { $rec{$_}{state} eq 'working' || $rec{$_}{state} eq 'blocked' } keys %rec;
    return unless @gone;
    delete @rec{@gone};
    $dirty = 1;
}

sub inherited_app {
    my ($id) = @_;
    while (1) {
        return $rec{$id}{app} if exists $rec{$id} && defined $rec{$id}{app};
        return undef if $id eq '';
        $id = ($id =~ m{\A(.*)/[^/]*\z}) ? $1 : '';
    }
}

sub summary {
    return undef unless %rec;
    my ($top) = sort {
        $RANK{ $rec{$b}{state} } <=> $RANK{ $rec{$a}{state} } || $rec{$b}{t} <=> $rec{$a}{t}
    } keys %rec;
    my $r = $rec{$top};
    my %count;
    $count{ $_->{state} }++ for values %rec;
    my @out = ("seq=$seq", "state=$r->{state}");
    push @out, "id=$top" if $top ne '';
    my $app = inherited_app($top);
    push @out, "app=$app" if defined $app;
    for my $k (qw(kind progress title msg)) {
        push @out, "$k=$r->{$k}" if defined $r->{$k};
    }
    push @out, 'n=' . scalar(keys %rec);
    push @out, "working=$count{working}" if $count{working};
    push @out, "blocked=$count{blocked}" if $count{blocked};
    return join(':', @out);
}

sub push_state {
    $seq++;
    my $s = summary();
    my @cmd = ($TMUX, '-S', $SOCK);
    if (defined $s) {
        system(@cmd, 'set-option', '-p', '-t', $PANE, '@myghost_psp', $s);
    } else {
        system(@cmd, 'set-option', '-p', '-u', '-t', $PANE, '@myghost_psp');
    }
    $dirty = 0;
    $last_push = Time::HiRes::time();
}

sub scan {
    my $consumed = 0;
    my $keep;
    pos($buf) = 0;
    while ($buf =~ /\e(\]7501;|\]133;A|c)/g) {
        my ($start, $after, $tag) = ($-[0], $+[0], $1);
        if ($tag eq 'c') { %rec = (); $dirty = 1; $consumed = $after; next }
        if ($tag eq ']133;A') { prompt(); $consumed = $after; next }

        # Find the end: BEL or ESC \. Another ESC, CAN or SUB aborts it.
        my $limit = 4096 - 7;
        my $rest = substr($buf, $after, $limit + 2);
        if ($rest =~ /[\a\e\x18\x1a]/) {
            my $at = $-[0];
            my $c = substr($rest, $at, 1);
            if ($c eq "\e" && $at + 1 >= length($rest)) {
                $keep = $start;       # ESC at the very end: wait for more
                last;
            }
            my $done = ($c eq "\a") ? 1 : ($c eq "\e" && substr($rest, $at + 1, 1) eq '\\') ? 2 : 0;
            report(substr($rest, 0, $at)) if $done && $at <= $limit;
            $consumed = $after + $at + ($done || 1);
            pos($buf) = $consumed;
        } elsif (length($rest) > $limit) {
            $consumed = $after;       # too long: drop it
            pos($buf) = $consumed;
        } else {
            $keep = $start;           # unterminated so far
            last;
        }
    }
    if (defined $keep) {
        $buf = substr($buf, $keep);
    } else {
        # Keep a tail that could be the start of a sequence split by the read.
        my $from = length($buf) - 7;
        $from = $consumed if $from < $consumed;
        $buf = $from > 0 ? substr($buf, $from) : $buf;
    }
}

while (1) {
    my $timeout = undef;
    if ($dirty) {
        my $wait = $PUSH_GAP - (Time::HiRes::time() - $last_push);
        $timeout = $wait > 0 ? $wait : 0;
    }
    my $rin = '';
    vec($rin, fileno(STDIN), 1) = 1;
    my $n = select(my $rout = $rin, undef, undef, $timeout);
    if ($n > 0) {
        my $got = sysread(STDIN, my $chunk, 65536);
        last unless $got;
        $buf .= $chunk;
        scan();
    }
    push_state() if $dirty && Time::HiRes::time() - $last_push >= $PUSH_GAP;
}
"""#
}
