#!/usr/bin/env perl
## Copyright © 2008, 2009 by Daniel Friesel <derf@derf.homelinux.org>
## License: WTFPL <http://sam.zoy.org/wtfpl>
## used in the screen hardstatus
use feature 'switch';
use strict;
use utf8;
use warnings;
my $hostname;
my @battery;
my @disks;
my $config;
my $confdir = "$ENV{HOME}/packages/screen/etc/screen.pl";
my %interval = (
	current => 10,
	ac      => 10,
	battery => 20,
);
local $|=1;

open(HOSTNAME, "</etc/hostname");
chomp($hostname = <HOSTNAME>);
close(HOSTNAME);

if (-r "$confdir/$hostname") {
	unless ($config = do("$confdir/$hostname")) {
		warn "couldn't parse config: $@" if $@;
		warn "couldn't do config: $!"    unless defined $config;
		warn "couldn't run config"       unless $config;
	}
}


if (-d '/sys/class/power_supply') {
	opendir(POWER, '/sys/class/power_supply');
	foreach(readdir(POWER)) {
		if (/^(BAT\d+)$/) {
			push(@battery, $1);
			last;
		}
	}
}

sub fromfile {
	my $file = shift;
	open(my $fh, '<', $file) or die("Cannot open $file: $!");
	my $content = <$fh>;
	close($fh);
	chomp($content);
	return($content);
}

sub print_ip {
	open(IP, "</tmp/ip") or return;
	print <IP>;
	close(IP);
}

sub print_mail {
	my $new_mail;
	opendir(MAIL, "$ENV{HOME}/Maildir/new") or return;
	$new_mail = scalar(@{[readdir(MAIL)]});
	closedir(MAIL);
	$new_mail -= 2;
	if ($new_mail) {
		print "\@$new_mail";
	}
}

sub print_jabber {
	my $unread = fromfile("/tmp/.jabber-unread-$>");
	if ($unread > 0) {
		print "J$unread";
	}
}

sub print_fan {
	open(FAN, '</proc/acpi/fan/FAN/state') or return;
	if (<FAN> =~ /on/) {
		print 'fan';
	} else {
		print '   ';
	}
	close(FAN);
}

sub print_ibm_fan {
	my $speed;
	open(FAN, '<', '/sys/devices/platform/thinkpad_hwmon/fan1_input') or return;
	$speed = <FAN>;
	close(FAN);
	chomp($speed);
	print "fan:$speed";
}


sub kraftwerk_print_thermal {
	my @cputemp;
	@cputemp = split(/\n/, qx{sensors -A});
	$cputemp[1]=~s/^[^\.]*(\d{2}\.\d).*$/$1/g;
	$cputemp[4]=~s/^[^\d]*(\d{2}\.\d).*$/$1/g;
	$cputemp[5]=~s/^[^\d]*(\d{2}\.\d).*$/$1/g;
	print "board $cputemp[4] proc $cputemp[1] ($cputemp[5])";
}

sub aneurysm_print_thermal {
	my @sensors;
	my $current;
	my $regex = '^[^\:]+\:\s+\+?(\d+).+$';
	my ($fan, $chip, $cpu, $sys);

	@sensors = split(/\n/, qx{sensors -A});
	foreach(@sensors) {
		/$regex/;
		$current = lc((split(/\:/))[0]);
		if ($current eq 'fan2') {
			$fan = $1;
		} elsif ($current eq 'chip temp') {
			$chip = $1;
		} elsif ($current eq 'cpu temp') {
			$cpu = $1;
		} elsif ($current eq 'sys temp') {
			$sys = $1;
		}
	}

	print "fan:$fan chip:$chip cpu:$cpu sys:$sys";
}

sub print_ibm_thermal {
	my @thermal;
	my $i;
	my $prefix = '/sys/devices/platform/thinkpad_hwmon';
	return unless (-d $prefix);
	printf(
		'cpu:%d ?:%d board:%d gpu:%d bat:%d:%d ',
		fromfile("$prefix/temp1_input")/1000,
		fromfile("$prefix/temp2_input")/1000,
		fromfile("$prefix/temp3_input")/1000,
		fromfile("$prefix/temp4_input")/1000,
		fromfile("$prefix/temp5_input")/1000,
		fromfile("$prefix/temp7_input")/1000,
	);
}

sub print_battery {
	my $bat = shift;
	my %info;
	my ($capacity, $health);
	my $prefix = "/sys/class/power_supply/$bat";
	$info{remaining_capacity} = fromfile("$prefix/energy_now")/1000;
	$info{last_full_capacity} = fromfile("$prefix/energy_full")/1000;
	$info{design_capacity} = fromfile("$prefix/energy_full_design")/1000;
	$info{charging_state} = lc(fromfile("$prefix/status"));
	$info{present_rate} = fromfile("$prefix/current_now")/1000;
	$info{present} = fromfile("$prefix/present");
	print(lc($bat));
	if ($info{present} == 0) {
		return;
	}

	# prevent division by zero
	foreach (\@info{'last_full_capacity', 'design_capacity', 'present_rate'}) {
		unless ($$_) {
			$$_ = -1;
		}
	}

	$capacity = $info{remaining_capacity} * 100 / $info{last_full_capacity};
	$health = $info{last_full_capacity} * 100 / $info{design_capacity};

	if ($info{charging_state} eq 'discharging') {
		$interval{current} = $interval{battery};
	} else {
		$interval{current} = $interval{ac};
	}

	given($info{charging_state}) {
		when('discharging') {
			printf(
				' v %.f%%, %02d:%02.fh remaining',
				$capacity,
				$info{remaining_capacity} / $info{present_rate},
				($info{remaining_capacity} * 60 / $info{present_rate}) % 60,
			);
		}
		when('charging') {
			printf(
				' ^ %.f%%, %02d:%02.fh remaining',
				$capacity,
				($info{last_full_capacity} - $info{remaining_capacity}) / $info{present_rate},
				(($info{last_full_capacity} - $info{remaining_capacity}) * 60 / $info{present_rate}) % 60,
			);
		}
		when(['charged', 'unknown']) {
			printf(
				' = %.f%%, %.f%% health',
				$capacity,
				$health,
			);
		}
		default {
			printf(
				' ? %.f%%',
				$capacity,
			);
		}
	}
}

sub print_np {
	if (-f '/tmp/np') {
		open(NP, '</tmp/np') or return;
		print <NP>;
		close(NP);
	} else {
		print qx{/home/derf/bin/np | tr -d "\n"};
	}
}

sub print_meminfo {
	my ($mem, $memfree);
	my ($swap, $swapfree);
	open(MEMINFO, '<', '/proc/meminfo') or return;
	while(<MEMINFO>) {
		chomp;
		/^([^:]+): *(\d+) kB$/;
		given($1) {
			when('MemTotal') {$mem = $2}
			when('MemFree')  {$memfree = $2}
			when('Buffers')  {$memfree += $2}
			when('Cached')   {$memfree += $2}
			when('SwapTotal'){$swap = $2}
			when('SwapFree') {$swapfree = $2}
		}
	}
	close(MEMINFO);
	foreach (\$mem, \$memfree, \$swap, \$swapfree) {
		$$_ /= 1024;
		$$_ = int($$_);
	}
	printf('mem:%d ', $mem-$memfree);
	printf('swap:%d', $swap-$swapfree);
}

sub print_hddtemp {
	my $disk = shift;
	my $hddtemp = '/usr/sbin/hddtemp';
	return unless (-u $hddtemp);
	chomp(my $temp = qx{$hddtemp -n /dev/$disk});
	unless(length($temp)) {
		$temp = '-';
	}
	print "$disk:$temp";
}

sub print_interfaces {
	my @devices;
	my $ifpre = '/sys/class/net';
	my $device;
	opendir(my $ifdir, $ifpre) or return;
	@devices = grep { ! /^\./ } readdir($ifdir);
	closedir($ifdir);
	device: foreach $device (@devices) {
		open(my $ifstate, '<', "$ifpre/$device/operstate") or next;
		if (<$ifstate> eq "up\n") {
			print "$device";
		}
		close($ifstate);
	}
}

sub space {
	print '   ';
}

if (-u '/usr/sbin/hddtemp' and opendir(DISKS, '/sys/block')) {
	foreach(readdir(DISKS)) {
		next unless /^[hs]d[a-z]$/;
		open(CAP, '<', "/sys/block/$_/capability") or next;
		chomp(my $cap = <CAP>);
		close(CAP);
		if ($cap == 10 or $cap == 12 or $cap == 50) {
			push(@disks, $_);
		}
	}
	closedir(DISKS);
}

do {
	if ($config->{meminfo}) {
		print_meminfo;
	}
	if (-d '/sys/devices/platform/thinkpad_hwmon') {
		space;
		print_ibm_fan;
		space;
		print_ibm_thermal;
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
		space;
		print_interfaces;
	}

	foreach (@battery) {
		space;
		print_battery($_);
	}

	if (-d "$ENV{HOME}/Maildir/new") {
		space;
		print_mail;
	}
	if (-r "/tmp/.jabber-unread-$>") {
		print_jabber;
	}
	if (-r '/tmp/ip') {
		space;
		print_ip;
	}
	if (-r '/tmp/np') {
		space;
		print_np;
	}
	print "\n";
} while (sleep($interval{current}))
