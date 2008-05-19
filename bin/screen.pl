#!/usr/bin/env perl
use strict;
use warnings;
my $hostname;

open(HOSTNAME, "</etc/hostname");
chomp($hostname = <HOSTNAME>);
close(HOSTNAME);

sub print_ip {
	open(IP, "</tmp/ip");
	print <IP>;
	close(IP);
}

sub print_mail {
	my $new_mail;
	opendir(MAIL, '/home/derf/Maildir/new');
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
	open(FAN, '</proc/acpi/fan/FAN/state');
	if (<FAN> =~ /on/) {
		print 'fan';
	} else {
		print '   ';
	}
	close(FAN);
}

sub print_thermal {
	my ($acpitemp, @cputemp);
	if (-f '/proc/acpi/thermal_zone/THRM/temperature') {
		open(THRM, '</proc/acpi/thermal_zone/THRM/temperature');
		chomp($acpitemp = <THRM>);
		close(THRM);
		$acpitemp =~ s/[^\d]//g;
	}
	@cputemp = split(/\n/, qx{sensors -A});
	$cputemp[1]=~s/[^0-9]//g;
	$cputemp[2]=~s/[^0-9]//g;
	$cputemp[1]=~s/........$//;
	$cputemp[2]=~s/.......$//;
	print "board $cputemp[1] proc ";
	if (defined($acpitemp)) {
		print "$acpitemp ($cputemp[2])";
	} else {
		print $cputemp[2];
	}
}

sub print_ibm_thermal {
	my @cputemp;
	open(THERMAL, '</proc/acpi/ibm/thermal');
	@cputemp = split(/\ +/, <THERMAL>);
	close(THERMAL);
	for (my $i=0; $i<4; $i++) {
		print "$cputemp[$i] ";
	}
}

sub print_acpi {
	print qx{acpi | tr -d "\n"};
}

sub print_np {
	if (-f '/tmp/np') {
		open(NP, '</tmp/np');
		print <NP>;
		close(NP);
	} else {
		print qx{/home/derf/bin/np | tr -d "\n"};
	}
}

while (sleep(10)) {
	if ($hostname eq 'kraftwerk') {
		print_ip;
		print '  ';
		print_mail;
		print '  ';
		print_fan;
		print '  ';
		print_thermal;
	} elsif ($hostname eq 'nemesis') {
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
