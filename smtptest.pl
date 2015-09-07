#!/usr/bin/perl -w

use strict;
no strict 'refs';

use Getopt::Long qw(:config no_auto_abbrev require_order);
use IO::Socket;
use IO::Socket::INET;
use IO::Select;
use Time::HiRes qw(gettimeofday);
use POSIX qw(strftime);
use JSON;
use Data::Dumper;

chomp (my $hostname = `hostname`);
chomp (my $username = `id -u -n`);

my $quiet;
my %long_opts = (sockets => 1, max => 1, spam => 0, payload => 0, remote => "mx", port => 25, subject => "test");
if (open FILE, "<", "$ENV{HOME}/.smtptest.conf")
{
    my $data = do { local $/ = undef; <FILE> };
    my $json = decode_json($data) or die;
    @long_opts{keys %$json} = values %$json;
    close FILE;
}
GetOptions("quiet", => \$quiet,
           "sockets=i" => \$long_opts{sockets},
	   "max=i" => \$long_opts{max},
	   "remote=s" => \$long_opts{remote},
	   "port=i" => \$long_opts{port},
	   "mail-from" => \$long_opts{mail_from},
	   "recipient=s" => \$long_opts{recipient},
	   "spam=i" => \$long_opts{spam},
	   "payload=i" => \$long_opts{payload},
	   "null" => \$long_opts{null},
	   "subject=s" => \$long_opts{subject},
    ) or &logfail("bad options");

&usage unless defined($long_opts{mail_from}) && defined($long_opts{recipient});

sub usage
{
    printf "usage: %s [-quiet] [-sockets=NUMBER] [-max=NUMBER] [-remote=mx.domain.tld] [-port=PORT] [-spam=LEVEL] [-payload=TEXT] [-null] [-subject=TEXT] -mail-from=postmaster\@domain.tld -recipient=postmaster\@domain.tld\n", $0;
    exit 1;
}

my $sel_r = IO::Select->new();
my $sel_w = IO::Select->new();

my %sockets;

for (1 .. $long_opts{sockets})
{
    &mail_start_thread;
}
my $now_string = strftime "%Y %m %d %H:%M:%S", localtime;
print "all threads started $now_string.\n";

#sleep 1;

my $total = 0;
my $last_time = &get_time;
my $mail_per_second_limit = 150;

$SIG{INT} = sub
{
    print "Total nb mails: $total\n";
    exit 0;
};

while (1)
{
#    print "SELECT on ".$sel_r->count()."\n";
    my ($r, $w) = IO::Select->select($sel_r, $sel_w, undef);
    foreach (@$r)
    {
#	next unless $sockets{$_};
	&do_read($_);
    }
    foreach (@$w)
    {
#	print "WRITE\n";
#	next unless $sockets{$_};
	&do_write($_);
    }
}

sub mail_start_thread
{
    my $s = IO::Socket::INET->new(PeerAddr => $long_opts{remote}, PeerPort => $long_opts{port}) or die;
    $sockets{$s} = {"s" => $s, state => "ehlo"};
#    print "add socket s/".$s." hash/".$sockets{$s}."\n";
    $sel_r->add($s);
#    print "count ".$sel_r->count()."\n";
}

sub get_recipient($)
{
    my ($d) = @_;

    (my $r = $long_opts{recipient}) =~ s/X(?=X*@)/int(rand(10))/oge;
    return $r;
}

sub get_time
{
    my ($seconds, $microseconds) = gettimeofday;

    return $seconds * 1000 + $microseconds / 1000;
}

sub do_read
{
    my ($s) = @_;

    my $buf;
    my $ret = sysread $s, $buf, 1024;
    if (not defined $ret)
    {
	die "not defined\n";
    }
    elsif (!$ret)
    {
#	die "read 0 $? $!";
	&mail_read_eof($sockets{$s});
	$sel_r->remove($s);
	$sel_w->remove($s);
	delete $sockets{$s};
    }
    &filter_read($sockets{$s}, \$buf);
}

sub filter_read($$)
{
    my ($d, $buf) = @_;

    my $buffer = \$d->{buffer};
    $$buffer = [undef] unless ref $$buffer;
    while ($$buf =~ m/(.*)(\r?\n)?/go)
    {
	$$buffer->[$#{$$buffer}] .= $1;
#	print "--> $1\n" if defined $2;
	push @{$$buffer}, undef if defined $2;
    }
    pop @{$$buffer} if !(length $$buf || length $$buffer->[$#{$$buffer}]);
    while (scalar @{$$buffer} && length $$buffer->[0])
    {
	my $line = shift @{$$buffer};
	&mail_read($d, $line);
    }
}

sub do_write($)
{
    my ($s) = @_;

#    print "do_write to $d\n";
#    print "len : ".($d->{outbuf} || "NULL")."\n";
    my $buffer = \$sockets{$s}{outbuf};
#    print "syswrite ".($d || "NULL")." ".($$buffer || "NULL")."\n";
    my $ret = syswrite $sockets{$s}{s}, $$buffer;
    substr $$buffer, 0, $ret, "";
    $sel_w->remove($s) unless length $$buffer;
}

sub mail_write
{
    my ($d, $data) = @_;

    print ">>> $data\n" unless $quiet;
    $d->{outbuf} .= $data."\r\n";
#    print "add select hash/".$d." s/".$d->{s}." state/".$d->{state}."\n";
    $sel_w->add($d->{s});
}

sub mail_read
{
    my ($d, $line) = @_;

    print "<<< $line\n" unless $quiet;
    return unless $line =~ m/^(\d+) /;
    my $code = $1;
    my $func = "mail_read_".$d->{state};
    my $ret = &{$func}($d, $code, $line);
    if (!$ret)
    {
	die "$line\n";
    }
}

sub mail_read_eof($)
{
    my ($d) = @_;

#    print Dumper($d);
    print "Warning: EOF during mail transaction\n" unless $d->{state} eq "rcpt";
    die "EOF from remote host";
}


sub mail_read_ehlo($$$)
{
    my ($d, $code, $line) = @_;

    if ($code == 220)
    {
	&mail_write($d, "EHLO FLEX");
	$d->{state} = "mail";
    }
}

sub mail_read_mail($$$)
{    
    my ($d, $code, $line) = @_;

    if ($code == 250)
    {
	&mail_write($d, "MAIL FROM: <".$long_opts{mail_from}.">");
	$d->{state} = "rcpt";
    }
}

sub mail_read_rcpt($$$)
{
    my ($d, $code, $line) = @_;

    if ($code == 250)
    {
	$d->{recipient} = &get_recipient($d);
	&mail_write($d, "RCPT TO: <".$d->{recipient}.">");
	$d->{state} = "data";
    }
}

sub mail_read_data($$$)
{
    my ($d, $code, $line) = @_;

    if ($code == 250)
    {
	&mail_write($d, "DATA");
	$d->{state} = "body";
    }
}

sub mail_read_body($$$)
{
    my ($d, $code, $line) = @_;

    if ($code == 354)
    {
	my $msgid = join("", ("A".."Z", "a".."z", "0".."9")[map { rand 62 } 1 .. 16]);
	&mail_write($d, "X-ProXaD-SC: X-ProXaD-SC: state=".($long_opts{spam} < 100 ? "HAM" : "SPAM")." score=".$long_opts{spam});
	&mail_write($d, "Message-ID: <".$msgid."\@domain.tld>");
	&mail_write($d, "From: ".$long_opts{mail_from});
	&mail_write($d, "To: ".$d->{recipient});
	&mail_write($d, "Subject: [Test SMTP] $0 to ".$long_opts{remote}." : ".$long_opts{subject});
	&mail_write($d, "");
	&mail_write($d, "Bonjour,");
	&mail_write($d, "");
	&mail_write($d, "Je suis un script magique, qui fait des checks.");
	&mail_write($d, "");
	if ($long_opts{spam} < 100)
	{
	    &mail_write($d, "A cet effet, je me presente, afin de ne pas etre catche par l'antispam,");
	    &mail_write($d, "car il est mechant et je ne l'aime pas.");
	}
	else
	{
	    &mail_write($d, "J'ai un score de SPAM de ".$long_opts{spam}." donc par defaut je devrais");
	    &mail_write($d, "tomber dans le courrier indiserable.");
	}
	&mail_write($d, "");
	&mail_write($d, "Merci beaucoup.");
	&mail_write($d, "Caractere null: \0") if $long_opts{null};
	&mail_write($d, "");
	&mail_write($d, "Cordialement,");
	&mail_write($d, "");
	if ($long_opts{payload})
	{
	    &mail_write($d, "PS : Voici le payload...");
	    my $s = "> ".join("", ("A".."Z", "a".."z", "0".."9")[map { rand 62 } 1 .. 76]);
	    for (my $i = 0; $i < $long_opts{payload} * 1024; $i += length $s)
	    {
		&mail_write($d, $s);
	    }
	    &mail_write($d, "");
	    
	}
	&mail_write($d, "--");
	&mail_write($d, "Le script vivant.");
	&mail_write($d, ".");
	$d->{state} = "end";
    }
}

sub mail_read_end
{
    my ($d, $code, $line) = @_;

    if ($code == 250)
    {
#	print "MAIL SENT ".$d->{recipient}."\n";
	if (++$total % $mail_per_second_limit == 0)
	{
	    my $ms = $mail_per_second_limit * 1000 / (&get_time - $last_time);
	    while ($ms >= $mail_per_second_limit)
	    {
		select undef, undef, undef, 0.050;
		$ms = $mail_per_second_limit * 1000 / (&get_time - $last_time);
#		printf "new mails/second : %.02f\n", $ms;
	    }
	    printf "mails/second : %.02f\n", $ms;
	    $last_time = &get_time;
	}
	if ($total == $long_opts{max})
	{
	    print "maximum number of mails have been sent (".$long_opts{max}.")\n";
	    exit 0;
	}
#	die if $total == 1000;
	&mail_read_mail($d, $code, $line);
    }
}
