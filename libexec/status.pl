#!/usr/bin/env perl
## Copyright © 2008-2010 by Daniel Friesel <derf@derf.homelinux.org>
## License: WTFPL <http://sam.zoy.org/wtfpl>
## used in various status bars
use 5.010;
use strict;
use warnings;

use Date::Format;
use File::Slurp;
use POSIX qw(mkfifo);

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

my $smartphone = '/dev/disk/by-id/usb-HTC_Android_Phone_SH18HRT00504-0:0';

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
	my ($percent, $max_dots) = @_;
	$max_dots  //= 5;
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

sub print_aneurysm {
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

	$line{fan} = 'fan ' . chr(0xc0 + sprintf('%.f', $speed / 400));

	return;
}

sub print_eee_thermal {
	my $prefix = '/sys/class/hwmon/hwmon0';
	my $governor
	  = fromfile('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor');
	my $sign = q{:};

	debug('eee_thermal');
	if ( not -e "$prefix/temp1_input" ) {
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

	$line{'thermal'}
	  = sprintf( '%s%d', $sign, fromfile("$prefix/temp1_input") / 1000, );
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

	$line{bat} = chr(0xa9 - sprintf('%.f', $capacity * 0.09));

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
				' %02d:%02.fh',
				$info{remaining_capacity} / $info{present_rate},
				( $info{remaining_capacity} * 60 / $info{present_rate} ) % 60,
			);
		}
		when ('charging') {
			$line{'bat'} .= sprintf(
				' %c %02d:%02.fh',
				0xb2,
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
			$line{'bat'} .= sprintf( ' %c (%.f%%)',
				0xb2, $health, );
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
		$np = substr($np, -50);
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
	$line{mem} = sprintf( '%c %dM', 0xb0, $mem - $memfree, );
	if ( $swap > 0 ) {
		$line{'mem'} .= sprintf( ' swap %d', $swap - $swapfree, );
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

	if (-e $smartphone) {
		push(@media, chr(0xb3));
	}

	if (@media == 0) {
		$line{media} = undef;
	}
	else {
		$line{media} = sprintf('[%s]',
			join(q{ }, @media));
	}
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
		elsif ($device eq 'wlan0') {
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

	$line{net} = ((@updevices or $wlan{unconnected}) ? q{} : undef);

	foreach my $device (@updevices) {

		if ( $device eq 'wlan0' ) {
			$line{net} .= chr(0xaa + sprintf('%.f', $wlan{link} * 0.05));
		}
		if ($device eq 'lan') {
			$line{net} .= 'l';
		}
	}
	if ($wlan{unconnected}) {
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

	if ( count(5) and $hostname eq 'descent' ) {
#		print_eee_fan;
		print_eee_thermal;
	}

	if ( count(20) ) {
		$line{hddtemp} = 'hdd';
		foreach my $disk (@disks) {
			print_hddtemp($disk);
		}

	}

	if ( count(5) ) {
		print_interfaces;
		print_battery;
		print_media;
	}

	if ( count(20) ) {
		print_rfkill();
	}

	if (    count(10)
		and -e '/tmp/ssh-derf.homelinux.org-22-derf'
		and not $on_umts )
	{
		print_aneurysm;
	}
	$line{'date'} = strftime( '%Y-%m-%d %H:%M', @{ [ localtime(time) ] } );
	print_time_pulse();

	$buf = q{};
	for my $element (
		@line{
			'np', 'fan', 'mem', 'thermal', 'hddtemp', 'rfkill',
			'net', 'bat', 'media', 'mail',
		}
	  )
	{
		if ( defined $element ) {
			$buf .= "${element}   ";
		}
	}

	$buf .= $line{date} . q{ } . $line{pulse};

	system( 'xsetroot', '-name', $buf );
	sleep( $interval{current} );

	if ( $counter++ == 600 ) {
		$counter = 0;
		%line    = undef;
	}

	sleep( $interval{'current'} );
}
