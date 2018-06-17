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

my $buf;
my $hostname;
my @disks;
my $counter  = 0;
my $debug    = 0;
my %interval = (
	current => 1,
	ac      => 1,
	battery => 2,
);
my %line;
local $| = 1;

my @utf8vbar = ( ' ', qw( ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ) );
my @utf8hbar = ( ' ', qw( ▏ ▎ ▍ ▌ ▋ ▊ ▉ █ ) );

my @utf8vbarx = (qw( ! _ ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ));

my @utf8hbar2
  = ( ( map { "$_ " } @utf8hbar ), ( map { "█$_" } @utf8hbar[ 1 .. 7 ] ) );
my @utf8hbar3 = ( ( map { "$_ " } @utf8hbar2 ),
	( map { "██$_" } @utf8hbar[ 1 .. 7 ] ) );
my @utf8hbar4 = (
	( map { "$_ " } @utf8hbar3 ),
	( map { "███$_" } @utf8hbar[ 1 .. 7 ] )
);

my $detailed = 0;

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

sub fromfile {
	my $file = shift;
	my $content;
	{
		local $/ = undef;
		open( my $fh, '<', $file ) or return q{};
		$content = <$fh>;
		close($fh);
	}
	$content //= q{};
	chomp($content);
	return $content;
}

sub print_arclight {
	my $ssh_command
	  = 'ssh -o ConnectTimeout=2 -o ServerAliveInterval=5 -o ServerAliveCountMax=2';

	debug('print_arclight');

	my $raw = qx|$ssh_command arclight 'setopt extended_glob; while read md short; do 
		[[ -n \$(echo Maildir/\$md/new/*(N) Maildir/\$md/cur/*~*,*S*(N)) ]] && echo \$short; true;
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

		# original value range 0 .. 70, transformed to 0 .. 49
		my $ll = $+{ll} - 21;
		if ( $ll < 0 ) {
			$ll = 0;
		}
		$line{wifi} = sprintf( 'w %s', $utf8vbar[ $ll * @utf8vbar / 50 ] );
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
			my $temp = fromfile("${prefix}/${hwmon}/temp1_input") / 1000;
			if ( $temp >= 60 ) {
				push( @temps, $temp );
			}
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
	my $psdir;
	my @battery_data;
	my %sum_info = (
		remaining_capacity => 0,
		last_full_capacity => 0,
		design_capacity    => 0,
		present_rate       => 0,
		online             => 0,
		discharging        => 0,
	);

	if ( not opendir( $psdir, '/sys/class/power_supply' ) ) {
		$line{bat} = undef;
		return;
	}

	$line{bat} = q{};
	for my $dir ( readdir($psdir) ) {
		my $prefix = "/sys/class/power_supply/$dir";
		push( @battery_data, get_battery_data($prefix) );
		$line{bat} .= print_battery_data( $battery_data[-1] );
	}

	for my $info_ref (@battery_data) {
		for my $key ( keys %sum_info ) {
			if ( defined $info_ref->{$key} ) {
				$sum_info{$key} += $info_ref->{$key};
			}
		}
	}

	if ( $sum_info{last_full_capacity} ) {
		$line{bat} .= sprintf( ' %.f%%',
			$sum_info{remaining_capacity} * 100 / $sum_info{last_full_capacity}
		);
	}
	if (    $sum_info{discharging}
		and $sum_info{remaining_capacity}
		and $sum_info{present_rate} )
	{
		if ( $sum_info{remaining_capacity} / $sum_info{present_rate} > 1 ) {
			$line{bat} .= sprintf( ' (%dh)',
				$sum_info{remaining_capacity} / $sum_info{present_rate} );
		}
		else {
			$line{bat} .= sprintf( ' (%dm)',
				$sum_info{remaining_capacity} * 60 / $sum_info{present_rate} );
		}
	}

	closedir($psdir);
	return;
}

sub get_battery_data {
	my ($prefix) = @_;
	my %info;

	if ( -e "${prefix}/online" ) {

		# AC adapter
		if ( fromfile("${prefix}/online") ) {
			$info{online} = 1;
		}
	}
	elsif ( -e "${prefix}/present" ) {
		$info{remaining_capacity} = fromfile("$prefix/energy_now") / 1000;
		$info{last_full_capacity} = fromfile("$prefix/energy_full") / 1000;
		$info{design_capacity} = fromfile("$prefix/energy_full_design") / 1000;
		$info{alarm_capacity}  = fromfile("$prefix/alarm") / 1000;
		$info{charging_state}  = lc( fromfile("$prefix/status") );
		$info{present_rate}    = fromfile("$prefix/power_now") / 1000;
		$info{present_voltage} = fromfile("$prefix/voltage_now") / 1000;
		$info{design_min_voltage}
		  = fromfile("$prefix/voltage_min_design") / 1000;
		$info{present} = fromfile("$prefix/present");

		if ( $info{design_capacity} == 0 ) {
			$info{remaining_capacity} = fromfile("$prefix/charge_now") / 1000;
			$info{last_full_capacity} = fromfile("$prefix/charge_full") / 1000;
			$info{design_capacity}
			  = fromfile("$prefix/charge_full_design") / 1000;
			$info{present_rate} = fromfile("$prefix/current_now") / 1000;
		}
		if ( $info{charging_state} eq 'discharging' ) {
			$info{discharging} = 1;
		}

		# prevent division by zero
		foreach ( @info{qw( last_full_capacity design_capacity present_rate )} )
		{
			if ( $_ == 0 ) {
				$_ = -1;
			}
		}

		$info{capacity}
		  = $info{remaining_capacity} * 100 / $info{last_full_capacity};
		$info{health}
		  = $info{last_full_capacity} * 100 / $info{design_capacity};
	}

	return \%info;
}

sub print_battery_data {
	my ($info_ref) = @_;
	my %info       = %{$info_ref};
	my $ret        = q{};

	if ( $info{online} ) {

		# Actually an AC adaptor
		return q{↯};
	}
	if ( not $info{present} ) {

		# Probably not a battery
		return q{};
	}

	my $lsep = '▕';
	my $rsep = '▏';

	if ( $info{remaining_capacity} < $info{alarm_capacity} ) {
		$rsep .= '!';
	}

	my $utf8vbar_pos  = int( $info{capacity} * @utf8vbarx / 100.1 );
	my $utf8vbar_elem = '▒';
	if ( $utf8vbar_pos < @utf8vbarx ) {
		$utf8vbar_elem = $utf8vbarx[$utf8vbar_pos];
	}

	if ($detailed) {
		given ( $info{charging_state} ) {
			when ('discharging') {
				$ret .= sprintf(
					'%.f%% %s%s%s %d:%02.f',
					$info{capacity},
					$lsep,
					$utf8vbar_elem,
					$rsep,
					$info{remaining_capacity} / $info{present_rate},
					( $info{remaining_capacity} * 60 / $info{present_rate} )
					  % 60,
				);
			}
			when ('charging') {
				$rsep .= '⇧';
				$ret  .= sprintf(
					'%.f%% %s%s%s %d:%02.f',
					$info{capacity},
					$lsep,
					$utf8vbar_elem,
					$rsep,
					( $info{last_full_capacity} - $info{remaining_capacity} )
					  / $info{present_rate},
					(
						(
							    $info{last_full_capacity}
							  - $info{remaining_capacity}
						) * 60 / $info{present_rate}
					) % 60,
				);
			}
			when ('full') {
				$ret .= sprintf( '(%.f%%) %s%s%s',
					$info{health}, $lsep, $utf8vbar_elem, $rsep );
			}
			default {

				# not charging, reported as unknown
				$ret .= sprintf( '%.f%% %s%s%s',
					$info{capacity}, $lsep, $utf8vbar_elem, $rsep );
			}
		}
	}
	else {
		given ( $info{charging_state} ) {
			when ('discharging') {
			}
			when ('charging') {
				$rsep .= '⇧';
			}
		}
		$ret .= sprintf( '%s%s%s', $lsep, $utf8vbar_elem, $rsep, );
	}
	return $ret;
}

sub print_battery_bt {
	my $psdir;

	if ( not opendir( $psdir, '/sys/class/power_supply' ) ) {
		$line{bat_bt} = undef;
		return;
	}

	my $lsep = '▕';
	my $rsep = '▏';

	$line{bat_bt} = q{};
	for my $dir ( readdir($psdir) ) {
		my $prefix = "/sys/class/power_supply/$dir";
		if ( $dir =~ m{ ..:..:..:..:..:.. }x and -r "$prefix/capacity" ) {
			my $capacity = fromfile("$prefix/capacity");
			$line{bat_bt} .= sprintf( '%s%s%s',
				$lsep, $utf8vbarx[ $capacity * @utf8vbarx / 101 ], $rsep, );
		}
	}
	return;
}

sub print_unison {
	$line{unison} = undef;

	if ( -r '/tmp/misc.log' ) {
		my $line = File::ReadBackwards->new('/tmp/misc.log')->readline;
		if ( $line =~ m{ Deleting } ) {
			$line{unison} = '↻';
		}
		elsif ( $line =~ m{to /home} ) {
			$line{unison} = '↧';
		}
		elsif ( $line =~ m{from /home} ) {
			$line{unison} = '↥';
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

	if ( $mem_ratio < 0.75 ) {
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
			if ( $cap ~~ [ 10, 12, 50, 51, 52 ] ) {
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
		print_battery_bt();
	}

	if (
		count(5)
		and (  $hostname eq 'illusion'
			or $hostname eq 'momentum'
			or $hostname eq 'vatos' )
	  )
	{

		print_tp_fan;
		print_sys_thermal;
		print_bt;
		print_wifi;
	}

	if ( count(5) and $hostname eq 'descent' ) {
		print_sys_thermal;
		print_wifi;
	}

	if ( count(5) ) {
		print_meminfo;
		print_battery;
		print_media;
		print_unison;
	}

	if ( count(10)
		and ( -e '/tmp/ssh-arclight.derf0.net-22-derf' ) )
	{
		print_arclight;
	}
	$line{date} = strftime( '%H:%M', @{ [ localtime(time) ] } );

	$buf = q{};
	for my $element (
		@line{
			'unison',  'mail', 'media', 'fan',    'mem', 'thermal',
			'hddtemp', 'bt',   'wifi',  'bat_bt', 'bat'
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
