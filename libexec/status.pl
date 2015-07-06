#!/usr/bin/env perl
## Copyright © 2008-2010 by Daniel Friesel <derf@finalrewind.org>
## License: WTFPL <http://sam.zoy.org/wtfpl>
## used in various status bars
use 5.010;
use strict;
use warnings;

use Date::Format;
use File::ReadBackwards;
use File::Slurp;
use POSIX qw(mkfifo);

my $buf;
my $hostname;
my @disks;
my $on_battery = 0;
my $counter    = 0;
my $debug      = 0;
my %interval   = (
	current => 1,
	ac      => 1,
	battery => 2,
);
my %line;
local $| = 1;

my $smartphone = '/dev/disk/by-id/usb-HTC_Android_Phone_SH18HRT00504-0:0';

my @utf8vbar = ( ' ', qw( ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ) );
my @utf8hbar = ( ' ', qw( ▏ ▎ ▍ ▌ ▋ ▊ ▉ █ ) );

my @utf8hbar2
  = ( ( map { "$_ " } @utf8hbar ), ( map { "█$_" } @utf8hbar[ 1 .. 7 ] ) );
my @utf8hbar3 = ( ( map { "$_ " } @utf8hbar2 ),
	( map { "██$_" } @utf8hbar[ 1 .. 7 ] ) );
my @utf8hbar4 = (
	( map { "$_ " } @utf8hbar3 ),
	( map { "███$_" } @utf8hbar[ 1 .. 7 ] )
);

if ( $ARGV[0] and ( $ARGV[0] eq '-d' ) ) {
	$debug = 1;
}

open( my $hostfh, '<', '/etc/hostname' )
  or die("Cannot open /etc/hostname: $!");
chomp( $hostname = <$hostfh> );
close($hostfh) or die("Cannot close /etc/hostname: $!");

mkfifo( '/tmp/.derf-notify', 0777 );
open( my $notification_fh, '<', '/tmp/.derf-notify' );

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

sub print_lastlight {
	my $ssh_command
	  = 'ssh -o ConnectTimeout=2 -o ServerAliveInterval=5 -o ServerAliveCountMax=2';

	debug('print_lastlight');

	my $raw = qx|$ssh_command lastlight 'while read md short; do 
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
}

sub print_bt {
	debug('bt');

	if ( -e '/sys/class/bluetooth/hci0' ) {
		$line{bt} = 'bt';
	}
	else {
		$line{bt} = undef;
	}
}

sub print_wifi {
	debug('wifi');

	if ( -e '/sys/class/net/wlan0' and -e '/proc/self/net/wireless' ) {
		my $status
		  = ( split( /\n/, fromfile('/proc/self/net/wireless') ) )[-1];
		$status =~ m/ ^ \s* wlan0: \s+ \d+ \s+ (?<ll>\d+) /x;
		my $ll = $+{ll} == 70 ? 69 : $+{ll};
		$line{wifi} = sprintf( 'w:%s', $utf8vbar[ $ll * @utf8vbar / 70 ] );
	}
	else {
		$line{wifi} = undef;
	}
}

sub print_tp_fan {
	debug('tp_fan');

	if ( not -r '/sys/devices/platform/thinkpad_hwmon/fan1_input' ) {
		$line{fan} = undef;
		return;
	}

	my $speed = fromfile('/sys/devices/platform/thinkpad_hwmon/fan1_input');

	if ( $speed == 0 ) {
		$line{fan} = undef;
	}
	else {
		$line{fan}
		  = sprintf( 'fan %s', $utf8vbar[ $speed * @utf8vbar / 9000 ] );
	}

	return;
}

sub print_sys_thermal {
	my $prefix = '/sys/class/hwmon';
	my @temps;
	my $governor
	  = fromfile('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor');
	my $sign = q{:};

	debug('sys_thermal');
	for my $hwmon (qw(hwmon0 hwmon1 hwmon2 hwmon3 hwmon4 hwmon5 hwmon6)) {
		if ( -e "${prefix}/${hwmon}/temp1_input" ) {
			push( @temps, fromfile("${prefix}/${hwmon}/temp1_input") / 1000 );
		}
	}
	if ( not @temps ) {
		$line{thermal} = undef;
		return;
	}

	given ($governor) {
		when ('ondemand')     { $sign = q{|} }
		when ('conservative') { $sign = q{.} }
		when ('powersave')    { $sign = q{_} }
		when ('userspace')    { $sign = q{-} }
		when ('performance')  { $sign = q{^} }
	}

	$line{'thermal'} = sprintf( '%s%s', join( q{ }, @temps ), $sign );
	return;
}

sub print_battery {
	my %info;
	my ( $capacity, $health );
	my $prefix = '/sys/class/power_supply/BAT0';

	if ( not -e $prefix ) {
		$line{bat} = chr(0xb2);
		return;
	}

	my $lsep = '[';
	my $rsep = ']';

	$info{remaining_capacity} = fromfile("$prefix/energy_now") / 1000;
	$info{last_full_capacity} = fromfile("$prefix/energy_full") / 1000;
	$info{design_capacity}    = fromfile("$prefix/energy_full_design") / 1000;
	$info{alarm_capacity}     = fromfile("$prefix/alarm") / 1000;
	$info{charging_state}     = lc( fromfile("$prefix/status") );
	$info{present_rate}       = fromfile("$prefix/power_now") / 1000;
	$info{present_voltage}    = fromfile("$prefix/voltage_now") / 1000;
	$info{design_min_voltage} = fromfile("$prefix/voltage_min_design") / 1000;
	$info{present}            = fromfile("$prefix/present");

	if ( $info{design_capacity} == 0 ) {
		$info{remaining_capacity} = fromfile("$prefix/charge_now") / 1000;
		$info{last_full_capacity} = fromfile("$prefix/charge_full") / 1000;
		$info{design_capacity} = fromfile("$prefix/charge_full_design") / 1000;
		$info{present_rate}    = fromfile("$prefix/current_now") / 1000;
	}

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

	#	$line{bat} = chr(0xa9 - sprintf('%.f', $capacity * 0.09));
	$line{bat} = q{};

	if ( $info{charging_state} eq 'discharging' ) {
		$interval{current} = $interval{battery};
		$on_battery = 1;
	}
	else {
		$interval{current} = $interval{ac};
		$on_battery = 0;
	}

	if ( $info{present_voltage} < $info{design_min_voltage} ) {
		$lsep = $rsep = '!';
	}
	if ( $info{remaining_capacity} < $info{alarm_capacity} ) {
		$lsep = $rsep = '!!';
	}

	given ( $info{charging_state} ) {
		when ('discharging') {
			$line{'bat'} .= sprintf(
				'%s%s%s %d%% %02d:%02.fh',
				$lsep,
				$utf8hbar4[ $capacity * @utf8hbar4 / 101 ],
				$rsep,
				$capacity,
				$info{remaining_capacity} / $info{present_rate},
				( $info{remaining_capacity} * 60 / $info{present_rate} ) % 60,
			);
		}
		when ('charging') {
			$line{'bat'} .= sprintf(
				'%s%s%s %d%%',
				$lsep,
				$utf8hbar4[ $capacity * @utf8hbar4 / 101 ],
				$rsep,
				$capacity,
				( $info{last_full_capacity} - $info{remaining_capacity} )
				  / $info{present_rate},
				(
					( $info{last_full_capacity} - $info{remaining_capacity} )
					* 60 / $info{present_rate}
				) % 60,
			);
		}
		when ('full') {
			$line{'bat'} .= sprintf( '[%s] (%.f%%)',
				$utf8hbar4[ $capacity * @utf8hbar4 / 101 ], $health );
		}
		default {
			# not charging, reported as unknown
			$line{'bat'} .= sprintf( '%s%s%s %.f%%',
				$lsep, $utf8hbar4[ $capacity * @utf8hbar4 / 101 ],
				$rsep, $capacity );
		}
	}
	return;
}

sub print_unison {
	$line{unison} = undef;

	if ( -r '/tmp/misc.log' ) {
		my $line = File::ReadBackwards->new('/tmp/misc.log')->readline;
		if ( $line =~ m{ Deleting } ) {
			$line{unison} = '|--|';
		}
		elsif ( $line =~ m{to /home} ) {
			$line{unison} = '|vv|';
		}
		elsif ( $line =~ m{from /home} ) {
			$line{unison} = '|^^|';
		}
	}
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

	my $mem_ratio = ( $mem - $memfree ) / $mem;

	if ( $mem_ratio < 0.2 ) {
		$line{mem} = undef;
	}
	else {
		$line{mem} = sprintf( 'mem %s', $utf8vbar[ $mem_ratio * @utf8vbar ] );
		if ( $swapfree < $swap ) {
			my $swap_ratio = ( $swap - $swapfree ) / $swap;
			$line{mem}
			  .= sprintf( '   swp %s', $utf8vbar[ $swap_ratio * @utf8vbar ] );
		}
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
		return;
	}
	$line{'hddtemp'} .= " $temp";
	return;
}

sub print_media {
	debug('media');

	my @media = grep { not -l "/media/$_" } read_dir('/media');

	if ( -e $smartphone ) {
		push( @media, 'phone' );
	}

	if ( @media == 0 ) {
		$line{media} = undef;
	}
	else {
		$line{media} = sprintf( '[%s]', join( q{ }, @media ) );
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

	my $notification = <$notification_fh>;
	if ( $notification and length($notification) ) {
		chomp $notification;
		system( 'xsetroot', '-name', $notification );
		sleep(5);
	}

	if ( count(60) ) {
		scan_for_disks();
	}

	if ( count(5) and $hostname eq 'illusion' ) {

		print_tp_fan;
		print_sys_thermal;
		print_bt;
		print_wifi;
	}

	if ( count(5) and $hostname eq 'descent' ) {
		print_sys_thermal;
		print_wifi;
	}

	if ( count(20) ) {
		$line{hddtemp} = 'hdd';
		foreach my $disk (@disks) {
			print_hddtemp($disk);
		}
		if ( $line{hddtemp} eq 'hdd' ) {
			$line{hddtemp} = undef;
		}

	}

	if ( count(5) ) {
		print_meminfo;
		print_battery;
		print_media;
		print_unison;
	}

	if ( count(10)
		and -e '/tmp/ssh-lastlight.derf0.net-22-derf' )
	{
		print_lastlight;
	}
	$line{date} = strftime( '%Y-%m-%d %H:%M', @{ [ localtime(time) ] } );

	$buf = q{};
	for my $element (
		@line{
			'fan',  'mem', 'thermal', 'hddtemp', 'unison', 'bt',
			'wifi', 'bat', 'media',   'mail',
		}
	  )
	{
		if ( defined $element ) {
			$buf .= "${element}   ";
		}
	}

	$buf .= $line{date};

	system( 'xsetroot', '-name', $buf );
	sleep( $interval{current} );

	if ( $counter++ == 600 ) {
		$counter = 0;
		%line    = undef;
	}

	sleep( $interval{'current'} );
}
