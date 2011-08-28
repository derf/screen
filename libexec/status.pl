#!/usr/bin/env perl
## Copyright © 2008-2010 by Daniel Friesel <derf@derf.homelinux.org>
## License: WTFPL <http://sam.zoy.org/wtfpl>
## used in various status bars
use 5.010;
use strict;
use utf8;
use warnings;

use Date::Format;

my $buf;
my $hostname;
my @disks;
my $mailpre    = "$ENV{HOME}/Maildir";
my $confdir    = "$ENV{HOME}/packages/screen/etc/screen.pl";
my $on_battery = 0;
my $on_umts    = 0;
my $counter    = 0;
my $debug      = 0;
my %interval   = (
	current => 1,
	ac      => 1,
	battery => 2,
);
my %line;
local $| = 1;

if ( $ARGV[0] and ( $ARGV[0] eq '-d' ) ) {
	$debug = 1;
}

open( my $hostfh, '<', '/etc/hostname' )
  or die("Cannot open /etc/hostname: $!");
chomp( $hostname = <$hostfh> );
close($hostfh) or die("Cannot close /etc/hostname: $!");

sub count {
	my ($count) = @_;
	return ( ( $counter == 0 ) or ( ( $counter % $count ) == 0 ) );
}

sub debug {
	my ($msg) = @_;
	if ($debug) {
		say $msg;
	}
}

sub bar {
	my ($percent) = @_;
	my $max_dots  = 5;
	my $ret       = '[';
	my $dots = $percent / ( 100 / $max_dots );

	$ret .= '=' x int($dots);

	if ( $percent != 100 ) {
		given ( $dots - int($dots) ) {
			when ( $_ < 0.25 ) { $ret .= ' ' }
			when ( $_ < 0.75 ) { $ret .= '-' }
			default            { $ret .= '=' }
		}
	}

	$ret .= ' ' x ( $max_dots - int($dots) - 1 );

	$ret .= ']';

	return $ret;
}

sub fromfile {
	my $file = shift;
	my $content;
	{
		local $/ = undef;
		open( my $fh, '<', $file ) or return q{};
		$content = <$fh>;
		close($fh);
	}
	chomp($content);
	return $content;
}

sub short_bytes {
	my @post = ( '', 'k', 'M', 'G' );
	my $bytes = shift;
	while ( $bytes > 1000 ) {
		$bytes /= 1000;
		shift @post;
	}
	return sprintf( '%d%s', $bytes, $post[0] );
}

sub print_aneurysm {
	my $unread = 0;
	my $icq    = 0;
	my $icinga = q{};
	my $ssh_command
	  = 'ssh -o ConnectTimeout=2 -o ServerAliveInterval=5 -o ServerAliveCountMax=2';

	debug('print_aneurysm');

	my $raw = qx|$ssh_command aneurysm 'while read md short; do 
		[[ -n \$(echo Maildir/\$md/new/*(N)) ]] && echo \$short; true;
		done < Maildir/maildirs'|;

	if ( $? >> 8 ) {
		$raw = 'error';
	}

	if ( length($raw) ) {
		$line{'mail'} = '{' . join( ' ', split( /\n/, $raw ) ) . '}';
	}
	else {
		$line{'mail'} = undef;
	}

	$unread = qx|$ssh_command aneurysm 'cat /tmp/.jabber-unread-derf'|;

	if ( $unread > 0 ) {
		$line{'jabber'} = 'Jabber';
	}
	else {
		$line{'jabber'} = undef;
	}

	$icq = qx|$ssh_command aneurysm 'wc -l < .ysm/afk-log'|;

	if ( $icq > 0 ) {
		$line{'icq'} = 'ICQ';
	}
	else {
		$line{'icq'} = undef;
	}
}

sub print_eee_fan {
	debug('eee_fan');
	my $speed = fromfile('/sys/devices/platform/eeepc/hwmon/hwmon1/fan1_input');
	$line{'fan'} = "fan:${speed}";
	return;
}

sub print_eee_thermal {
	my $prefix = '/sys/class/hwmon/hwmon0';
	my $governor
	  = fromfile('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor');
	my $sign = q{:};

	debug('eee_thermal');
	if ( not -e "$prefix/temp1_input" ) {
		return;
	}

	given ($governor) {
		when ('ondemand')     { $sign = q{|} }
		when ('conservative') { $sign = q{.} }
		when ('powersave')    { $sign = q{_} }
		when ('userspace')    { $sign = q{-} }
		when ('performance')  { $sign = q{^} }
	}

	$line{'thermal'}
	  = sprintf( 'cpu%s%d', $sign, fromfile("$prefix/temp1_input") / 1000, );
	return;
}

sub print_battery {
	my %info;
	my ( $capacity, $health );
	my $prefix = '/sys/class/power_supply/BAT0';

	if ( not -e $prefix ) {
		delete $line{bat};
		return;
	}

	$info{remaining_capacity} = fromfile("$prefix/charge_now") / 1000;
	$info{last_full_capacity} = fromfile("$prefix/charge_full") / 1000;
	$info{design_capacity}    = fromfile("$prefix/charge_full_design") / 1000;
	$info{charging_state}     = lc( fromfile("$prefix/status") );
	$info{present_rate}       = fromfile("$prefix/current_now") / 1000;
	$info{present}            = fromfile("$prefix/present");

	debug('battery');

	if ( $info{present} == 0 ) {
		return;
	}

	# prevent division by zero
	foreach ( @info{ 'last_full_capacity', 'design_capacity', 'present_rate' } )
	{
		if ( $_ == 0 ) {
			$_ = -1;
		}
	}

	$capacity = $info{remaining_capacity} * 100 / $info{last_full_capacity};
	$health   = $info{last_full_capacity} * 100 / $info{design_capacity};

	$line{'bat'} = bar($capacity);

	if ( $info{charging_state} eq 'discharging' ) {
		$interval{current} = $interval{battery};
		$on_battery = 1;
	}
	else {
		$interval{current} = $interval{ac};
		$on_battery = 0;
	}

	given ( $info{charging_state} ) {
		when ('discharging') {
			$line{'bat'} .= sprintf(
				' - %.f%% %02d:%02.fh',
				$capacity,
				$info{remaining_capacity} / $info{present_rate},
				( $info{remaining_capacity} * 60 / $info{present_rate} ) % 60,
			);
		}
		when ('charging') {
			$line{'bat'} .= sprintf(
				' + %.f%% %02d:%02.fh',
				$capacity,
				( $info{last_full_capacity} - $info{remaining_capacity} )
				  / $info{present_rate},
				(
					( $info{last_full_capacity} - $info{remaining_capacity} )
					* 60 
					  / $info{present_rate}
				  ) % 60,
			);
		}
		when ('full') {
			$line{'bat'} .= sprintf( ' = %.f%% (%.f%%)', $capacity, $health, );
		}
		default {
			$line{'bat'} .= sprintf( ' ? %.f%%', $capacity, );
		}
	}
	return;
}

sub print_np {

	debug('np');

	my $np = qx{envify mpc -qf '[[%artist% - ]%title%]|[%file%]' current};
	if ( length($np) ) {
		$np =~ s/\n//s;
		$line{'np'} = $np;
	}
	else {
		$line{'np'} = undef;
	}
	return;
}

sub print_meminfo {
	my ( $mem,  $memfree );
	my ( $swap, $swapfree );

	debug('meminfo');

	foreach my $line ( split( /\n/, fromfile('/proc/meminfo') ) ) {
		$line =~ / ^ (?<key> [^:]+ ): \s* (?<value> \d+ ) \s kB $ /x or next;
		given ( $+{key} ) {
			when ('MemTotal') { $mem     = $+{value} }
			when ('MemFree')  { $memfree = $+{value} }
			when ('Buffers') { $memfree += $+{value} }
			when ('Cached')  { $memfree += $+{value} }
			when ('SwapTotal') { $swap     = $+{value} }
			when ('SwapFree')  { $swapfree = $+{value} }
		}
	}
	foreach ( $mem, $memfree, $swap, $swapfree ) {
		$_ /= 1024;
		$_ = int($_);
	}
	$line{mem} = sprintf( 'mem:%dM',
		$mem - $memfree,
	);
	if ( $swap > 0 ) {
		$line{'mem'} .= sprintf( ' swap:%d', $swap - $swapfree, );
	}
	return;
}

sub print_hddtemp {
	my $disk    = shift;
	my $hddtemp = '/usr/sbin/hddtemp';

	debug('hddtemp');

	if ( not -u $hddtemp ) {
		return;
	}
	chomp( my $temp = qx{$hddtemp -n SATA:/dev/$disk} );
	if ( length($temp) == 0 or $temp !~ /^ \d+ $/x ) {
		$temp = '-';
	}
	if ( length( $line{hddtemp} ) ) {
		$line{hddtemp} .= q{ };
	}
	$line{'hddtemp'} .= "$disk:$temp";
	return;
}

sub print_interfaces {
	my @devices;
	my @updevices;
	my $ifpre = '/sys/class/net';
	my %wlan;

	debug('interfaces');

	opendir( my $ifdir, $ifpre ) or return;
	@devices = grep { !/^\./ } readdir($ifdir);
	closedir($ifdir);

	DEVICE: foreach my $device (@devices) {
		open( my $ifstate, '<', "$ifpre/$device/operstate" ) or next;
		if ( <$ifstate> eq "up\n" or $device ~~ [ 'ppp0', 'pegasus' ] ) {
			push( @updevices, $device );
			if ( $device eq 'ppp0' ) {
				$on_umts = 1;
			}
		}
		close($ifstate);
	}

	foreach my $device (@updevices) {
		if ( $device eq 'wlan0' ) {
			my $line
			  = ( split( /\n/, fromfile('/proc/self/net/wireless') ) )[-1];
			$line =~ m/ ^ \s* wlan0: \s+ \d+ \s+ (?<ll>\d+) /x;
			$wlan{'link'} = $+{'ll'};
		}
	}

	$line{'net'} = undef;

	foreach my $device (@updevices) {
		my $extra = q{:};

		if ( $device eq 'wlan0' ) {
			$extra = bar( $wlan{'link'} );
		}

		$line{'net'} .= sprintf(
			'%s%s%s',
			$device, $extra,
			short_bytes(
				    fromfile("$ifpre/$device/statistics/rx_bytes")
				  + fromfile("$ifpre/$device/statistics/tx_bytes")
			),
		);
	}
	return;
}

sub scan_for_disks {
	@disks = ();

	if ( -u '/usr/sbin/hddtemp' and opendir( my $diskdir, '/sys/block' ) ) {
		foreach my $disk ( readdir($diskdir) ) {
			if ( $disk !~ / ^ sd [a-z] $/x ) {
				next;
			}
			my $cap = fromfile("/sys/block/$disk/capability");
			if ( $cap ~~ [ 10, 12, 50, 52 ] ) {
				push( @disks, $disk );
			}
		}
		closedir($diskdir);
	}
}

while (1) {

	debug("\ntick");

	if ( count(60) ) {
		scan_for_disks();
	}

	if ( count(10) and not $on_battery ) {
		print_np;
	}

	if ( count(2) ) {
		print_meminfo;
	}
	if ( count(5) and -d '/sys/devices/virtual/hwmon/hwmon0' ) {
		print_eee_fan;
		print_eee_thermal;
	}

	if ( count(20) ) {
		$line{'hddtemp'} = q{};
		foreach my $disk (@disks) {
			print_hddtemp($disk);
		}

	}

	if ( count(5) ) {
		print_interfaces;
	}

	if ( count(5) ) {
		print_battery();
	}

	if (    count(10)
		and -e '/tmp/ssh-derf.homelinux.org-22-derf'
		and not $on_umts )
	{
		print_aneurysm;
	}
	$line{'date'} = strftime( '%Y-%m-%d %H:%M', @{ [ localtime(time) ] } );

	$buf = q{};
	for my $element (
		@line{
			'np',  'mem',  'fan',    'thermal', 'hddtemp', 'net',
			'bat', 'mail', 'jabber', 'icq'
		}
	  )
	{
		if ( defined $element ) {
			$buf .= "${element}   ";
		}
	}

	$buf .= $line{'date'};

	system( 'xsetroot', '-name', $buf );
	sleep( $interval{current} );

	if ( $counter++ == 600 ) {
		$counter = 0;
		%line    = undef;
	}

	sleep( $interval{'current'} );
}
