#!/usr/bin/env perl
use feature 'switch';
use strict;
use utf8;
use warnings;
my $hostname;
local $|=1;

open(HOSTNAME, "</etc/hostname");
chomp($hostname = <HOSTNAME>);
close(HOSTNAME);

sub print_ip {
	open(IP, "</tmp/ip") or return;
	print <IP>;
	close(IP);
}

sub print_mail {
	my $new_mail;
	opendir(MAIL, '/home/derf/Maildir/new') or return;
	$new_mail = scalar(@{[readdir(MAIL)]});
	closedir(MAIL);
	$new_mail -= 2;
	if ($new_mail) {
		print "\@$new_mail";
	} else {
		print '  ';
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
	local $/;
	open(FAN, '</proc/acpi/ibm/fan') or return;
	$speed = (split(/\n/, <FAN>))[1];
	close(FAN);
	$speed =~ s/[^\d]//g;
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
	open(THERMAL, '</proc/acpi/ibm/thermal') or return;
	@thermal = split(/\ +/, <THERMAL>);
	close(THERMAL);
	$thermal[0] =~ s/.+\t//;
	for ($i=0; exists($thermal[$i]); $i++) {
		$thermal[$i] = '-' if $thermal[$i] == '-128';
	}
	print "cpu:$thermal[0] ";
	print "?:$thermal[1] ";
	print "board:$thermal[2] ";
	print "gpu:$thermal[3] ";
	print "bat:$thermal[4] $thermal[6] ";
}

sub print_acpi {
	my $acpi = qx{acpi};
	chomp($acpi);
	if ($acpi =~ /Battery (\d): (\w+), (\d+)%, (\S+)/) {
		print "bat$1: ";
		given($2) {
			# sadly, it seems the screen developers don't like unicode...
			when('Discharging') {print 'v'}
			when('Charging')    {print '^'}
		}
		print "$3%, $4 remaining";
	} else {
		print 'bat0: not present';
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

while (sleep(10)) {
	if ($hostname eq 'kraftwerk') {
		kraftwerk_print_thermal;
	} elsif ($hostname eq 'aneurysm') {
		print_ip;
		print '  ';
		print_mail;
		print '  ';
		aneurysm_print_thermal;
	} elsif ($hostname eq 'nemesis') {
		print_ibm_fan;
		print '  ';
		print_ibm_thermal;
		print '  ';
		print_acpi;
	} elsif ($hostname eq 'saviour') {
		print_np;
	} else {
		last;
	}
	print "\n";
}
