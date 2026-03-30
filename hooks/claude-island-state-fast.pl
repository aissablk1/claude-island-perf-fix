#!/usr/bin/env perl
# claude-island-state-fast.pl
# Drop-in replacement for claude-island-state.py — Perl version
# Handles PermissionRequest (bidirectional) and all other events
# Zero external dependencies (JSON::PP + IO::Socket::UNIX are core Perl)
# ─────────────────────────────────────────────────────────────────────────────
use strict;
use warnings;
use JSON::PP;
use IO::Socket::UNIX;
use IO::Select;

my $SOCKET_PATH = $ENV{CLAUDE_ISLAND_SOCKET} // '/tmp/claude-island.sock';
my $TIMEOUT     = 300;  # 5 minutes for permission decisions
my $MAX_INPUT   = 65536;  # 64 Ko max

# ── Guard: check socket exists and is owned by current user ──────────────────
exit 0 unless -S $SOCKET_PATH;
my $sock_uid = (stat($SOCKET_PATH))[4];
exit 0 unless defined $sock_uid && $sock_uid == $<;

# ── Read JSON from stdin (size-limited) ──────────────────────────────────────
my $raw = '';
read(STDIN, $raw, $MAX_INPUT);
exit 1 unless $raw;

my $data;
eval { $data = decode_json($raw) };
exit 1 unless $data && ref $data eq 'HASH';

my $event = $data->{hook_event_name} // '';

# ── Validate event against whitelist ─────────────────────────────────────────
my %valid_events = map { $_ => 1 } qw(
    UserPromptSubmit PreToolUse PostToolUse PermissionRequest
    Notification Stop SubagentStop SessionStart SessionEnd PreCompact
);
exit 1 unless $valid_events{$event};

# ── Get TTY (secure: no shell interpolation) ─────────────────────────────────
my $ppid = getppid();
my $tty;
if (open(my $ps_fh, '-|', 'ps', '-p', $ppid, '-o', 'tty=')) {
    chomp($tty = <$ps_fh> // '');
    close($ps_fh);
    if ($tty && $tty ne '??' && $tty ne '-') {
        $tty = "/dev/$tty" unless $tty =~ m{^/dev/};
    } else {
        $tty = undef;
    }
}

# ── Build state ──────────────────────────────────────────────────────────────
my %state = (
    session_id => $data->{session_id} // 'unknown',
    cwd        => $data->{cwd} // '',
    event      => $event,
    pid        => $ppid + 0,
);
$state{tty} = $tty if $tty;

my $wait_response = 0;

if ($event eq 'UserPromptSubmit') {
    $state{status} = 'processing';

} elsif ($event eq 'PreToolUse') {
    $state{status} = 'running_tool';
    $state{tool}   = $data->{tool_name} // '';
    $state{tool_use_id} = $data->{tool_use_id} if $data->{tool_use_id};
    # Filter tool_input: only metadata, not full content (security)
    if (my $ti = $data->{tool_input}) {
        if (ref $ti eq 'HASH') {
            if (exists $ti->{command}) {
                $state{tool_input} = { command => substr($ti->{command} // '', 0, 200) };
            } elsif (exists $ti->{file_path}) {
                $state{tool_input} = { file_path => $ti->{file_path} };
            } elsif (exists $ti->{pattern}) {
                $state{tool_input} = { pattern => $ti->{pattern} };
            } else {
                $state{tool_input} = { keys => [keys %$ti] };
            }
        }
    }

} elsif ($event eq 'PostToolUse') {
    $state{status} = 'processing';
    $state{tool}   = $data->{tool_name} // '';
    $state{tool_use_id} = $data->{tool_use_id} if $data->{tool_use_id};

} elsif ($event eq 'PermissionRequest') {
    $state{status} = 'waiting_for_approval';
    $state{tool}   = $data->{tool_name} // '';
    # Filter tool_input for permissions too
    if (my $ti = $data->{tool_input}) {
        if (ref $ti eq 'HASH') {
            if (exists $ti->{command}) {
                $state{tool_input} = { command => substr($ti->{command} // '', 0, 200) };
            } elsif (exists $ti->{file_path}) {
                $state{tool_input} = { file_path => $ti->{file_path} };
            } else {
                $state{tool_input} = { keys => [keys %$ti] };
            }
        }
    }
    $wait_response = 1;

} elsif ($event eq 'Notification') {
    my $ntype = $data->{notification_type} // '';
    exit 0 if $ntype eq 'permission_prompt';
    $state{status} = ($ntype eq 'idle_prompt') ? 'waiting_for_input' : 'notification';
    $state{notification_type} = $ntype;
    $state{message} = substr($data->{message} // '', 0, 500);

} elsif ($event eq 'Stop' || $event eq 'SubagentStop') {
    $state{status} = 'waiting_for_input';

} elsif ($event eq 'SessionStart') {
    $state{status} = 'waiting_for_input';

} elsif ($event eq 'SessionEnd') {
    $state{status} = 'ended';

} elsif ($event eq 'PreCompact') {
    $state{status} = 'compacting';
}

# ── Send to socket ───────────────────────────────────────────────────────────
my $sock = IO::Socket::UNIX->new(
    Type => SOCK_STREAM,
    Peer => $SOCKET_PATH,
) or exit 0;

$sock->autoflush(1);
$sock->print(encode_json(\%state));

if ($wait_response) {
    # PermissionRequest — wait for app decision with reliable timeout
    my $sel = IO::Select->new($sock);
    my $response = '';
    my $deadline = time() + $TIMEOUT;

    while (time() < $deadline) {
        my $remaining = $deadline - time();
        last unless $sel->can_read($remaining > 0 ? $remaining : 0);
        my $bytes = sysread($sock, my $chunk, 4096);
        last unless $bytes;
        $response .= $chunk;
        last if $response =~ /\}/;
    }

    if ($response) {
        eval {
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
        };
    }
}

close $sock;
exit 0;
