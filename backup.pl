#!perl

# backup the project

use strict;
use warnings;

use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);

my $now = strftime("%Y%m%d%H%M%S", localtime);    #yyyyMMddHHmmss
my $dst = "E:/versions/mindcab-$now.tar.gz";

my $ex = "--exclude=.*/*";
$ex="$ex --exclude=zig-out/*";
$ex="$ex --exclude=zig-pkg/*";
$ex="$ex --exclude=*.gz";
$ex="$ex --exclude=dvui-0.17.x/*";

my $cmd = "tar zcvf $dst $ex *";
print "$cmd\n";

system $cmd;



printf "\ndone, %.3f MiB\n", (-s $dst) / 1024 / 1024;
