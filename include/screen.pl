#!/usr/bin/env perl
## Copyright © 2008-2010 by Daniel Friesel <derf@derf.homelinux.org>
## License: WTFPL <http://sam.zoy.org/wtfpl>
## used in various status bars
use feature 'switch';
use strict;
use utf8;
use warnings;
use Date::Format;
use constant {
	LOOP_NONE => 0,
	LOOP_SCREEN => 1,
	LOOP_TMUX => 2,
	LOOP_DWM => 3,
	SSH_INT => '/tmp/ssh-aneurysm-22-derf',
	SSH_EXT => '/tmp/ssh-derf.homelinux.org-22-derf',
};

my $loop = shift || LOOP_NONE;
my $buf;
my $hostname;
my @battery;
my @disks;
my @maildirs;
my $mailpre = "$ENV{HOME}/Maildir";
my $config;
my $confdir = "$ENV{HOME}/packages/screen/etc/screen.pl";
my $ssh_command = 'ssh -o ConnectTimeout=2';
my $on_battery = 0;
my %interval = (
	current => 10,
	ac      => 10,
	battery => 20,
);
local $|=1;

open(my $hostfh, '<', '/etc/hostname') or die("Cannot open /etc/hostname: $!");
chomp($hostname = <$hostfh>);
close($hostfh) or die("Cannot close /etc/hostname: $!");

if (-r "$mailpre/maildirs") {
	open(my $mailfh, '<', "$mailpre/maildirs") or die("Cannot open $mailpre/maildirs: $!");

	while (my $line = <$mailfh>) {
		chomp $line;
		push(@maildirs, $line);
	}

	close($mailfh);
}

if (-r "$confdir/$hostname") {
	if (not ($config = do("$confdir/$hostname"))) {
		if ($@)                  {warn "couldn't parse config: $@"}
		if (not defined $config) {warn "couldn't do config: $!"}
		if (not $config)         {warn 'couldn\'t run config'}
	}
}

sub space {
	$buf .= '   ';
	return;
}

sub update_battery {
	@battery = ();
	if (-d '/sys/class/power_supply') {
		opendir(my $powdir, '/sys/class/power_supply');
		foreach (readdir($powdir)) {
			if (/ ^ (BAT \d+ ) $ /x) {
				push(@battery, $1);
				last;
			}
		}
		closedir($powdir);
	}
	return;
}

sub fromfile {
	my $file = shift;
	my $content;
	{
		local $/ = undef;
		open(my $fh, '<', $file) or return;
		$content = <$fh>;
		close($fh);
	}
	chomp($content);
	return $content;
}

sub short_bytes {
	my @post = ('', 'k', 'M', 'G');
	my $bytes = shift;
	while ($bytes > 1000) {
		$bytes /= 1000;
		shift @post;
	}
	return sprintf('%d%s', $bytes, $post[0]);
}

sub print_ip {
	if (-e '/tmp/ip') {
		$buf .= fromfile('/tmp/ip');
	}
	return;
}

sub print_mail {
	my $space = 0;

	if ($hostname ne 'aneurysm' and (-e SSH_INT or -e SSH_EXT)) {
		my $raw = qx|$ssh_command aneurysm 'for i (\$(cat Maildir/maildirs)) {
			[[ -n \$(echo Maildir/\$i/new/*(N)) ]] && echo \$i; true }'|;

		if ($? >> 8) {
			$raw = 'error';
		}

		if (length($raw)) {
			$buf .= 'mail:' . join(' ', split(/\n/, $raw));
		}
		return;
	}

	foreach my $maildir (@maildirs) {

		opendir(my $maildh, "$mailpre/$maildir/new") or next;
		my $new_mail = scalar(@{[readdir($maildh)]}) - 2;
		closedir($maildh);

		if ($new_mail) {
			if ($space) {
				$buf .= ' ';
			}
			else {
				$space = 1;
			}
			$buf .= "{$maildir}";
		}
	}
}

sub print_jabber {
	my $unread;
	if ($hostname ne 'aneurysm' and (-e SSH_INT or -e SSH_EXT)) {
		$unread = qx|$ssh_command aneurysm 'cat /tmp/.jabber-unread-derf'|;
	}
	else {
		$unread = fromfile('/tmp/.jabber-unread-derf');
	}
	if ($unread > 0) {
		$buf .= "J$unread";
	}
	return;
}

sub print_fan {
	if (fromfile('/proc/acpi/fan/FAN/state') =~ /on/) {
		$buf .= 'fan';
	}
	return;
}

sub print_ibm_fan {
	my $speed = fromfile('/sys/devices/platform/thinkpad_hwmon/fan1_input');
	$buf .= "fan:$speed";
	return;
}

sub print_eee_fan {
	my $speed = fromfile('/sys/devices/virtual/hwmon/hwmon0/fan1_input');
	$buf .= "fan:$speed";
	return;
}

sub kraftwerk_print_thermal {
	my @cputemp;
	@cputemp = split(/\n/, qx{sensors -A});
	$cputemp[1] =~ s/ ^ [^\.]* ( \d{2} \. \d ) .* $ /$1/gx;
	$cputemp[4] =~ s/ ^ [^\d]* ( \d{2} \. \d ) .* $ /$1/gx;
	$cputemp[5] =~ s/ ^ [^\d]* ( \d{2} \. \d ) .* $ /$1/gx;
	$buf .= "board $cputemp[4] proc $cputemp[1] ($cputemp[5])";
	return;
}

sub aneurysm_print_thermal {
	my $prefix = '/sys/class/i2c-adapter/i2c-0/0-002d';
	my $fan = '/sys/devices/platform/smsc47m1.1664/fan1_input';
	return unless (-d $prefix and -r $fan);

	$buf .= sprintf(
		'fan:%d  chip:%d  cpu:%d  sys:%d',
		fromfile($fan),
		fromfile("$prefix/temp1_input")/1000,
		fromfile("$prefix/temp2_input")/1000,
		fromfile("$prefix/temp3_input")/1000,
	);
	return;
}

sub print_ibm_thermal {
	my $prefix = '/sys/devices/platform/thinkpad_hwmon';
	return unless (-d $prefix);
	$buf .= sprintf(
		'cpu:%d ?:%d board:%d gpu:%d bat:%d:%d ',
		fromfile("$prefix/temp1_input")/1000,
		fromfile("$prefix/temp2_input")/1000,
		fromfile("$prefix/temp3_input")/1000,
		fromfile("$prefix/temp4_input")/1000,
		fromfile("$prefix/temp5_input")/1000,
		fromfile("$prefix/temp7_input")/1000,
	);
	return;
}

sub print_eee_thermal {
	my $prefix = '/sys/devices/virtual/hwmon/hwmon1';
	if (not -e "$prefix/temp1_input") {
		return;
	}
	$buf .= sprintf(
		'cpu:%d',
		fromfile("$prefix/temp1_input")/1000,
	);
	return;
}

sub print_battery {
	my $bat = shift;
	my %info;
	my ($capacity, $health);
	my $prefix = "/sys/class/power_supply/$bat";
	$info{remaining_capacity} = fromfile("$prefix/charge_now")/1000;
	$info{last_full_capacity} = fromfile("$prefix/charge_full")/1000;
	$info{design_capacity} = fromfile("$prefix/charge_full_design")/1000;
	$info{charging_state} = lc(fromfile("$prefix/status"));
	$info{present_rate} = fromfile("$prefix/current_now")/1000;
	$info{present} = fromfile("$prefix/present");
	$buf .= lc($bat);
	if ($info{present} == 0) {
		return;
	}

	# prevent division by zero
	foreach (@info{'last_full_capacity', 'design_capacity', 'present_rate'}) {
		if ($_ == 0) {
			$_ = -1;
		}
	}

	$capacity = $info{remaining_capacity} * 100 / $info{last_full_capacity};
	$health = $info{last_full_capacity} * 100 / $info{design_capacity};

	if ($info{charging_state} eq 'discharging') {
		$interval{current} = $interval{battery};
		$on_battery = 1;
	} else {
		$interval{current} = $interval{ac};
		$on_battery = 0;
	}

	given($info{charging_state}) {
		when('discharging') {
			$buf .= sprintf(
				' ↓ %.f%%, %02d:%02.fh remaining',
				$capacity,
				$info{remaining_capacity} / $info{present_rate},
				($info{remaining_capacity} * 60 / $info{present_rate}) % 60,
			);
		}
		when('charging') {
			$buf .= sprintf(
				' ↑ %.f%%, %02d:%02.fh remaining',
				$capacity,
				($info{last_full_capacity} - $info{remaining_capacity}) / $info{present_rate},
				(($info{last_full_capacity} - $info{remaining_capacity}) * 60 / $info{present_rate}) % 60,
			);
		}
		when('full') {
			$buf .= sprintf(
				' → %.f%%, %.f%% health',
				$capacity,
				$health,
			);
		}
		default {
			$buf .= sprintf(
				' ? %.f%%',
				$capacity,
			);
		}
	}
	return;
}

sub print_np {
	my $np = qx{/home/derf/bin/envify mpc -qf '[[%artist% - ]%title%]|[%file%]' current};
	if (length($np)) {
		$np =~ s/\n//s;
		$buf .= $np;
	}
	return;
}

sub print_meminfo {
	my ($mem, $memfree);
	my ($swap, $swapfree);
	foreach my $line (split(/\n/, fromfile('/proc/meminfo'))) {
		$line =~ / ^ (?<key> [^:]+ ): \s* (?<value> \d+ ) \s kB $ /x or next;
		given($+{key}) {
			when('MemTotal') {$mem = $+{value}}
			when('MemFree')  {$memfree = $+{value}}
			when('Buffers')  {$memfree += $+{value}}
			when('Cached')   {$memfree += $+{value}}
			when('SwapTotal'){$swap = $+{value}}
			when('SwapFree') {$swapfree = $+{value}}
		}
	}
	foreach ($mem, $memfree, $swap, $swapfree) {
		$_ /= 1024;
		$_ = int($_);
	}
	$buf .= sprintf(
		'mem:%d',
		$mem - $memfree,
	);
	if ($swap > 0) {
		$buf .= sprintf(
			' swap:%d',
			$swap - $swapfree,
		);
	}
	return;
}

sub print_hddtemp {
	my $disk = shift;
	my $hddtemp = '/usr/sbin/hddtemp';
	if (not -u $hddtemp) {
		return;
	}
	chomp(my $temp = qx{$hddtemp -n /dev/$disk});
	if (length($temp) == 0) {
		$temp = '-';
	}
	$buf .= "$disk:$temp";
	return;
}

sub print_interfaces {
	my @devices;
	my @updevices;
	my $ifpre = '/sys/class/net';
	my $essid;

	opendir(my $ifdir, $ifpre) or return;
	@devices = grep { ! /^\./ } readdir($ifdir);
	closedir($ifdir);

	DEVICE: foreach my $device (@devices) {
		open(my $ifstate, '<', "$ifpre/$device/operstate") or next;
		if (<$ifstate> eq "up\n" or $device eq 'ppp0') {
			push(@updevices, $device);
		}
		close($ifstate);
	}

	foreach my $device (@updevices) {
		if ($device eq 'ra0') {
			$essid = qx{/sbin/iwgetid ra0 --raw};
			chomp $essid;
		}
	}

	foreach my $device (@updevices) {
		space;
		$buf .= sprintf(
			'%s: %s',
			(($device eq 'ra0' and defined($essid)) ? "$device\[$essid]" : $device),
			short_bytes(fromfile("$ifpre/$device/statistics/rx_bytes")
			+ fromfile("$ifpre/$device/statistics/tx_bytes")),
		);
	}
	return;
}

if (-u '/usr/sbin/hddtemp' and opendir(my $diskdir, '/sys/block')) {
	foreach my $disk (readdir($diskdir)) {
		if ($disk !~ / ^ [hs] d [a-z] $/x) {
			next;
		}
		my $cap = fromfile("/sys/block/$disk/capability");
		if ($cap ~~ [10, 12, 50, 52]) {
			push(@disks, $disk);
		}
	}
	closedir($diskdir);
}

do {
	update_battery;
	if (!$on_battery and $config->{np}) {
		print_np;
		space;
	}
	if ($loop == LOOP_DWM) {
		$buf .= strftime('%Y-%m-%d %H:%M ', @{[localtime(time)]});
		space;
	}
	if ($config->{meminfo}) {
		print_meminfo;
	}
	if (-d '/sys/devices/platform/thinkpad_hwmon') {
		space;
		print_ibm_fan;
		space;
		print_ibm_thermal;
	}
	if (-d '/sys/devices/virtual/hwmon/hwmon0') {
		space;
		print_eee_fan;
		space;
		print_eee_thermal;
	}
	if ($hostname eq 'kraftwerk') {
		space;
		kraftwerk_print_thermal;
	} elsif ($hostname eq 'aneurysm') {
		space;
		aneurysm_print_thermal;
	}

	if ($config->{hddtemp}) {
		foreach(@disks) {
			space;
			print_hddtemp($_);
		}
	}

	if ($config->{interfaces}) {
		print_interfaces;
	}

	foreach (@battery) {
		space;
		print_battery($_);
	}

	if (-d "$ENV{HOME}/Maildir/new" or -e SSH_INT or -e SSH_EXT) {
		space;
		print_mail;
	}
	if (-r "/tmp/.jabber-unread-$>" or -e SSH_INT or -e SSH_EXT) {
		print_jabber;
	}
	if (-r '/tmp/ip') {
		space;
		print_ip;
	}
	if ($loop ~~ [LOOP_NONE, LOOP_SCREEN]) {
		print "$buf\n";
	}
	elsif ($loop == LOOP_TMUX) {
		system('tmux', 'set-option', 'status-right', $buf);
		system('tmux', 'set-option', 'status-left', strftime('%Y-%m-%d %H:%M ', @{[localtime(time)]}));
	}
	elsif ($loop == LOOP_DWM) {
		system('xsetroot', '-name', $buf);
	}
	if ($loop != LOOP_NONE) {
		sleep($interval{current});
	}
	$buf = '';
} while($loop);
