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
my $mailpre    = "$ENV{HOME}/Maildir";
my $confdir    = "$ENV{HOME}/packages/screen/etc/screen.pl";
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

my @utf8bar = ( ' ', qw( ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ) );

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

sub bar {
	my ( $percent, $max_dots ) = @_;
	$max_dots //= 5;
	my $ret = '[';
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

sub print_rfkill {
	my $prefix = '/sys/class/rfkill';
	opendir( my $dir, $prefix ) or return;
	my @entries = grep { /^[^.]/ } readdir($dir);
	my %rfkill;
	closedir($dir);

	for my $switch (@entries) {
		if ( fromfile("${prefix}/${switch}/state") == 1 ) {
			$rfkill{ fromfile("${prefix}/${switch}/name") } = 1;
		}
	}

	if ( $rfkill{'eeepc-bluetooth'} and $rfkill{'hci0'} ) {
		$line{rfkill} = 'bt';
	}
	else {
		$line{rfkill} = undef;
	}
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

sub print_sensors {
	my $raw = qx|sensors -u|;
	my $label;

	$line{thermal} = undef;

	for my $line ( split( /\n/, $raw ) ) {
		if ( $line =~ m{ ^ (?<label> \S+ ) : $ }ox ) {
			$label = $+{label};
		}
		elsif ( $line =~ m{ temp . _input: \s (?<value> \S+ ) $ }ox
			and $label !~ m{^temp}ox )
		{
			if ( $line{thermal} ) {
				$line{thermal} .= q{ };
			}
			$line{thermal} .= sprintf( "%s:%d", $label, $+{value} );
		}
	}
}

sub print_eee_fan {
	debug('eee_fan');

	if ( not -r '/sys/devices/platform/eeepc/hwmon/hwmon1/fan1_input' ) {
		$line{fan} = undef;
		return;
	}

	my $speed = fromfile('/sys/devices/platform/eeepc/hwmon/hwmon1/fan1_input');

	$line{fan} = 'fan ' . chr( 0xc0 + sprintf( '%.f', $speed / 400 ) );

	return;
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
		$line{fan} = sprintf( 'fan %s', $utf8bar[ $speed * @utf8bar / 9000 ] );
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
		$lsep = '!';
		$rsep = '!';
	}

	given ( $info{charging_state} ) {
		when ('discharging') {
			$line{'bat'} .= sprintf(
				'%s%s%s%s %d%% %02d:%02.fh',
				$lsep,
				'<' x int( $capacity * 0.059 ),
				' ' x ( 5 - int( $capacity * 0.059 ) ),
				$rsep,
				$capacity,
				$info{remaining_capacity} / $info{present_rate},
				( $info{remaining_capacity} * 60 / $info{present_rate} ) % 60,
			);
		}
		when ('charging') {
			$line{'bat'} .= sprintf(
				'%s%s%s%s %d%%',
				$lsep,
				'>' x int( $capacity * 0.059 ),
				' ' x ( 5 - int( $capacity * 0.059 ) ),
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
			$line{'bat'} .= sprintf( '[=====] (%.f%%)', $health, );
		}
		default {
			# not charging, reported as unknown
			$line{'bat'} .= sprintf( '%s%s%s%s %.f%%',
				$lsep,
				'=' x int( $capacity * 0.059 ),
				' ' x ( 5 - int( $capacity * 0.059 ) ),
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

sub print_np {

	debug('np');

	my $np = qx{mpc -qf '[[%artist% - ]%title%]|[%file%]' current};
	if ( length($np) ) {
		$np =~ s/\n//s;
		$np = substr( $np, -64 );
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

	my $mem_ratio = ( $mem - $memfree ) / $mem;

	if ( $mem_ratio < 0.2 ) {
		$line{mem} = undef;
	}
	else {
		$line{mem} = sprintf( 'mem %s', $utf8bar[ $mem_ratio * @utf8bar ] );
		if ( $swapfree < $swap ) {
			my $swap_ratio = ( $swap - $swapfree ) / $swap;
			$line{mem}
			  .= sprintf( '   swp %s', $utf8bar[ $swap_ratio * @utf8bar ] );
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
		$temp = '-';
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

# outdated
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
		if ( $device eq 'wlan0' ) {
			$wlan{unconnected} = 1;
		}
		close($ifstate);
	}

	foreach my $device (@updevices) {
		if ( $device eq 'wlan0' ) {
			my $line
			  = ( split( /\n/, fromfile('/proc/self/net/wireless') ) )[-1];
			$line =~ m/ ^ \s* wlan0: \s+ \d+ \s+ (?<ll>\d+) /x;
			$wlan{link} = $+{'ll'};
		}
	}

	$line{net} = ( ( @updevices or $wlan{unconnected} ) ? q{} : undef );

	foreach my $device (@updevices) {

		if ( $device eq 'wlan0' ) {
			$line{net} .= chr( 0xaa + sprintf( '%.f', $wlan{link} * 0.05 ) );
		}
		if ( $device eq 'lan' ) {
			$line{net} .= 'l';
		}
	}
	if ( $wlan{unconnected} ) {
		$line{net} .= chr(0xaf);
	}

	return;
}

# Skyshaper Pulse
# one day has 1000 pulses of 86.4 seconds each
sub print_time_pulse {
	my ( $sec, $min, $hour ) = gmtime(time);

	my $pulse = ( ( ( ( $hour * 60 ) + $min ) * 60 ) + $sec ) / 86.4;

	$line{pulse} = sprintf( '%d', $pulse );

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

	if ( count(10) and not $on_battery ) {
		print_np;
	}

	if ( count(5) and $hostname eq 'illusion' ) {

		print_tp_fan;
		print_sys_thermal;
	}

	if ( count(5) and $hostname eq 'descent' ) {
		print_sys_thermal;
	}

	if ( count(20) ) {
		$line{hddtemp} = 'hdd';
		foreach my $disk (@disks) {
			print_hddtemp($disk);
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
			'np',  'fan',    'mem', 'thermal', 'hddtemp', 'rfkill',
			'net', 'unison', 'bat', 'media',   'mail',
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
