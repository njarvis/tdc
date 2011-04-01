#!/usr/bin/perl -w
#
# CLI utility to fetch parameter values from a TDC controller
#
# Copyright (c) 2011 Neil Jarvis (neil@jarvis.name)
#
# Usage:
#
#  Show all available parameters and their values:
#   tdc.pl -tdcAddr=192.168.1.50
#
#  List all available parameters from controller:
#   tdc.pl -tdcAddr=192.168.1.50 -list
#
#  Fetch values for specific parameters from controller:
#   tdc.pl -tdcAddr=192.168.1.50 sensor0 relais0
#
#  Fetch value for a single parameter and output in MRTG format:
#   tdc.pl -tdcAddr=192.168.1.50 -mrtg=sensor0
# 
#  Fetch the LCD image and output to a PNG file called lcd.png:
#   tdc.pl -tdcAddr=192.168.1.50 -lcd=lcd.png
#
#  Fetch the LCD image 1000 times in a row and output to a sequence of PNG files called lcd0001.png, lcd0002.png etc.:
#   tdc.pl -tdcAddr=192.168.1.50 -lcd=lcd%04d.png -lcdCount=1000
#
# Advanced usage:
#   
#  Turn on debug (for any command): -debug
#
#  Execute a specific command: -proto=x -cmd="yyy"  (Use Ctrl-C to terminate)
#   - For example, to get device version string: 
#      tdc.pl -tdcAddr=192.168.1.50 -proto=0 -cmd="v?"
#
#########################################
#
# This program is free software; you can redistribute it and/or modify 
# it under the terms of the GNU General Public License as published by 
# the Free Software Foundation; either version 2 of the License, or 
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful, but 
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY 
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License 
# for more details.
# 
# You should have received a copy of the GNU General Public License along 
# with this program; if not, write to the Free Software Foundation, Inc., 
# 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
#
#########################################

use strict;
use IO::Socket::INET;
use Getopt::Long;
use GD;
use LockFile::Simple qw(lock trylock unlock);

my $debug = '';
my $tdcAddr = '';
my $tdcPort = 10001;
my $protoId = 0;
my $cmd = '';
my $listParameters;
my $mrtg = '';
my $lcd = '';
my $lcdCount = 0;

GetOptions('debug' => \$debug, 'tdcAddr=s' => \$tdcAddr, 'tdcPort=i' => \$tdcPort, 'proto=i' => \$protoId, 'cmd=s' => \$cmd,
	   'list' => \$listParameters, 'mrtg=s' => \$mrtg, 'lcd=s' => \$lcd, 'lcdCount=i' => \$lcdCount);

sub sendCmd {
    my ($tdcSock, $protoId, $cmd, $isASCIZ) = @_;
    my $cmdBuffer;
    
    if ($isASCIZ) {
	$cmdBuffer = pack('S<S<CCS<Z*', 0xaa47, 0, $protoId, 0, length($cmd) + 1, $cmd);
    } else {
	$cmdBuffer = pack('S<S<CCS<A*', 0xaa47, 0, $protoId, 0, length($cmd), $cmd);
    }

    if ($debug) {
	my ($hexDump) = unpack('H*', $cmdBuffer);
	print "cmd=$hexDump\n";
    }

    $tdcSock->print($cmdBuffer);
}

sub readRsp {
    my ($tdcSock, $payloadRef, $payloadSizeRef) = @_;
    my $readBuffer;
    my $bytesRead;
    my ($magic, $flags, $protoId, $extraHeaderSize);

    # Read header
    $bytesRead = $tdcSock->read($readBuffer, 8);
    if (defined $bytesRead) {
	($magic, $flags, $protoId, $extraHeaderSize, $$payloadSizeRef) = unpack('S<S<CCS<', $readBuffer);

	if ($debug) {
	    my ($hexDump) = unpack('H*', $readBuffer);
	    print "rsp=$hexDump\n";
	    printf(" magic=%04x, flags=%04x, protoId=%02x, extraHeaderSize=%d, payloadSize=%d\n", 
		   $magic, $flags, $protoId, $extraHeaderSize, $$payloadSizeRef);
	}
    } else {
	return (1);
    }
    
    # Read extra header
    if ($extraHeaderSize > 0) {
	$bytesRead = $tdcSock->read($readBuffer, $extraHeaderSize);
	if (defined $bytesRead) {
	    if ($debug) {
		my ($hexDump) = unpack('H*', $readBuffer);
		print " extraHeader=$hexDump\n";
	    }
	} else {
	    return (1);
	}
    }

    # Read checksum
    if ($flags & 0x1) {
	$bytesRead = $tdcSock->read($readBuffer, 2);
	if (defined $bytesRead) {
	    if ($debug) {
		my ($checksum) = unpack('S<', $readBuffer);
		print " checksum=%04X\n", $checksum;
	    }
	} else {
	    return (1);
	}
    }

    # Read payload
    $bytesRead = $tdcSock->read($$payloadRef, $$payloadSizeRef);
    if (defined $bytesRead) {
	if ($debug) {
	    my ($hexDump) = unpack('H*', $$payloadRef);
	    print " payload=$hexDump\n";
	}
    } else {
	return (1);
    }

    return (0);
}

sub getParameterValue {
    my ($tdcSock, $parameter) = @_;
    sendCmd($tdcSock, 2, "g" . $parameter, 1);

    my ($payload, $payloadSize);
    my $rc = readRsp($tdcSock, \$payload, \$payloadSize);
    my ($rsp, $parameterName, $value) = unpack('CZ*l<', $payload);

    return $value;
}

die "Must specify -tdcAddr on command line\n" if (length($tdcAddr) == 0);

# Get lock to prevent multiple clients accessing the TDC3 device
my $lock = LockFile::Simple->make(-autoclean => 1, -stale => 1, -warn => 0, -max => 20, -delay => 1);
print "Getting lock...\n" if $debug;
$lock->lock('/var/lock/tdc') || die("Can't lock");

print "Connecting to $tdcAddr:$tdcPort...\n" if $debug;

my $tdcSock = IO::Socket::INET->new(PeerAddr => $tdcAddr,
				    PeerPort => $tdcPort,
				    Proto    => 'tcp') or die "Can't bind : $@\n";

# Test mode: Issue cmd from command line
if (length($cmd)) {
    my ($payload, $payloadSize);

    $debug = 1;
    sendCmd($tdcSock, $protoId, $cmd, 1);
    do {
	my $rc = readRsp($tdcSock, \$payload, \$payloadSize);
	print "responsePayloadString='$payload'\n";	
	my ($hexDump) = unpack('H*', $payload);
	print "responsePayloadHex=   $hexDump\n";	
    } while (1);
}

# Get LCD image
if (length($lcd)) {
    my $lcdIndex = 1;
    my $img = new GD::Image(129, 64) || die "Could not create GD image: $@\n";
    my $white = $img->colorAllocate(255,255,255);
    my $black = $img->colorAllocate(0,0,0);       

    sendCmd($tdcSock, 1, "q", 0);

    while (1) {
	my $nextStripe = 0;
	
	sendCmd($tdcSock, 1, "d", 0);
	while (1) {
	    my ($payload, $payloadSize);
	    my $rc = readRsp($tdcSock, \$payload, \$payloadSize);
	    my ($rsp, $stripeIndex, $pixels) = unpack('CCH*', $payload);

	    if ($rsp == 0x64) {
		if ($stripeIndex == $nextStripe) {
		    print "Read image stripe $nextStripe: $pixels\n" if $debug;

		    for (my $byteI = 0; $byteI < 129; $byteI++) {
			my $byte = hex(substr($pixels, $byteI * 2, 2));
			for (my $bitI = 0; $bitI < 8; $bitI++) {
			    if ($byte & (1 << (7 - $bitI))) {
				$img->setPixel($byteI, ($nextStripe * 8) + $bitI, $black);
			    } else {
				$img->setPixel($byteI, ($nextStripe * 8) + $bitI, $white);
			    }
			}
		    }
		    
		    $nextStripe++;
		    last if $nextStripe == 8;
		}
	    }
	} 

	my $png_data = $img->png;
	if ($lcdCount) {
	    my $lcdFile = sprintf($lcd, $lcdIndex);
	    open (DISPLAY,"> $lcdFile") || die "Could not create output file $lcdFile: $@\n";
	    printf "Writing frame $lcdIndex\n";
	} else {
	    open (DISPLAY,"> $lcd") || die "Could not create output file $lcd: $@\n";
	}
	binmode DISPLAY;
	print DISPLAY $png_data;
	close DISPLAY;

	last if ($lcdCount == 0) || (++$lcdIndex > $lcdCount);
    }

    sendCmd($tdcSock, 1, "q", 0);

    $lock->unlock('/var/lock/tdc');
    exit;
}

# Get list of parameters
my %parameters;
sendCmd($tdcSock, 2, "e", 0);
while (1) {
    my ($payload, $payloadSize);
    my $rc = readRsp($tdcSock, \$payload, \$payloadSize);
    my ($rsp, $parameter) = unpack('CZ*', $payload);

    # Last parameter?
    last if (length($parameter) == 0);

    print "parameter=$parameter\n" if $debug;
    
    $parameters{$parameter} = 1;
}

# Dump parameters?
if ($listParameters) {
    foreach my $key (sort(keys %parameters)) {
	printf "%s\n", $key;
    }
    $lock->unlock('/var/lock/tdc');
    exit;
}

# Generate MRTG data?
if (length($mrtg)) {
    if ($parameters{$mrtg}) {
	my $value = getParameterValue($tdcSock, $mrtg);
	print "$value\n$value\n0\nTDC $mrtg value\n";
    } else {
	print "UNKNOWN\nUNKNOWN\n0\nTDC parameter $mrtg unknown\n";
    }
    $lock->unlock('/var/lock/tdc');
    exit;
}

# Fetch values for specified parameters
if (scalar(@ARGV) == 0) {
    foreach my $key (sort(keys %parameters)) {
	my $value = getParameterValue($tdcSock, $key);
	printf "%s = %i\n", $key, $value;
    }
} else {
    while (@ARGV) {
	my $parameter = shift(@ARGV);

	if ($parameters{$parameter}) {
	    printf "%s = %i\n", $parameter, getParameterValue($tdcSock, $parameter);
	}
    }
}
   
$lock->unlock('/var/lock/tdc');
