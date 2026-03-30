#!/usr/bin/env perl
# claude-island-state-fast.pl
# Drop-in replacement for claude-island-state.py — 5x faster
# Sends session state to ClaudeIsland.app via Unix socket
# For PermissionRequest: waits for user decision from the app
#
# Why faster:
#   Python (~73ms) : interpreter startup + module imports + subprocess for tty
#   Perl   (~15ms) : lighter interpreter + core modules only + no subprocess
#
# Zero external dependencies — uses only Perl core modules:
#   JSON::PP (core since 5.14), IO::Socket::UNIX (core), POSIX (core)
# ─────────────────────────────────────────────────────────────────────────────
use strict;
use warnings;
use JSON::PP;
use IO::Socket::UNIX;

my $SOCKET_PATH = '/tmp/claude-island.sock';
my $TIMEOUT     = 300;  # 5 minutes for permission decisions

# ── Read JSON from stdin ─────────────────────────────────────────────────────
my $raw = do { local $/; <STDIN> };
my $data;
eval { $data = decode_json($raw) };
exit 1 unless $data && ref $data eq 'HASH';

my $session_id = $data->{session_id} // 'unknown';
my $event      = $data->{hook_event_name} // '';
my $cwd        = $data->{cwd} // '';
my $tool_input = $data->{tool_input} // {};
my $tool_name  = $data->{tool_name} // '';
my $tool_use_id = $data->{tool_use_id} // '';

# ── Get TTY (without spawning subprocess when possible) ──────────────────────
my $tty;
my $ppid = getppid();

# Try /proc first (Linux), then ps (macOS) — ps is unavoidable on macOS
# but we use backticks directly instead of subprocess module
{
    my $proc_stat = "/proc/$ppid/fd/0";
    if (-e $proc_stat) {
        $tty = readlink($proc_stat);
    } else {
        chomp($tty = `ps -p $ppid -o tty= 2>/dev/null`);
        if ($tty && $tty ne '??' && $tty ne '-') {
            $tty = "/dev/$tty" unless $tty =~ m{^/dev/};
        } else {
            $tty = undef;
        }
    }
}

# ── Build state ──────────────────────────────────────────────────────────────
my %state = (
    session_id => $session_id,
    cwd        => $cwd,
    event      => $event,
    pid        => $ppid,
    tty        => $tty,
);

my $wait_response = 0;

if ($event eq 'UserPromptSubmit') {
    $state{status} = 'processing';

} elsif ($event eq 'PreToolUse') {
    $state{status}     = 'running_tool';
    $state{tool}       = $tool_name;
    $state{tool_input} = $tool_input;
    $state{tool_use_id} = $tool_use_id if $tool_use_id;

} elsif ($event eq 'PostToolUse') {
    $state{status}     = 'processing';
    $state{tool}       = $tool_name;
    $state{tool_input} = $tool_input;
    $state{tool_use_id} = $tool_use_id if $tool_use_id;

} elsif ($event eq 'PermissionRequest') {
    $state{status}     = 'waiting_for_approval';
    $state{tool}       = $tool_name;
    $state{tool_input} = $tool_input;
    $wait_response = 1;

} elsif ($event eq 'Notification') {
    my $ntype = $data->{notification_type} // '';
    # Skip permission_prompt — PermissionRequest hook handles it
    exit 0 if $ntype eq 'permission_prompt';
    $state{status} = ($ntype eq 'idle_prompt') ? 'waiting_for_input' : 'notification';
    $state{notification_type} = $ntype;
    $state{message} = $data->{message};

} elsif ($event eq 'Stop' || $event eq 'SubagentStop') {
    $state{status} = 'waiting_for_input';

} elsif ($event eq 'SessionStart') {
    $state{status} = 'waiting_for_input';

} elsif ($event eq 'SessionEnd') {
    $state{status} = 'ended';

} elsif ($event eq 'PreCompact') {
    $state{status} = 'compacting';

} else {
    $state{status} = 'unknown';
}

# ── Send to socket ───────────────────────────────────────────────────────────
my $sock = IO::Socket::UNIX->new(
    Type => SOCK_STREAM,
    Peer => $SOCKET_PATH,
) or exit 0;  # App not running — silently exit

$sock->autoflush(1);

my $json_out = encode_json(\%state);
$sock->print($json_out);

if ($wait_response) {
    # PermissionRequest — wait for app decision
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm $TIMEOUT;

        my $response = '';
        while (my $chunk = <$sock>) {
            $response .= $chunk;
            last if $response =~ /\}/;  # Complete JSON received
        }
        alarm 0;

        if ($response) {
            my $resp = decode_json($response);
            my $decision = $resp->{decision} // 'ask';
            my $reason   = $resp->{reason} // '';

            if ($decision eq 'allow') {
                print encode_json({
                    hookSpecificOutput => {
                        hookEventName => 'PermissionRequest',
                        decision => { behavior => 'allow' },
                    }
                });
            } elsif ($decision eq 'deny') {
                print encode_json({
                    hookSpecificOutput => {
                        hookEventName => 'PermissionRequest',
                        decision => {
                            behavior => 'deny',
                            message  => $reason || 'Denied by user via ClaudeIsland',
                        },
                    }
                });
            }
        }
    };
}

close $sock;
exit 0;
