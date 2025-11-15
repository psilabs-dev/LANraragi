package LANraragi::Utils::RotatingLog;

use strict;
use warnings;
use utf8;

use POSIX;
use Compress::Zlib;
use Config;

use Mojo::Base 'Mojo::Log';
use Mojo::File;
use LANraragi::Utils::Redis qw(redis_decode);
use LANraragi::Model::Config;

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

BEGIN {
    if ( !IS_UNIX ) {
        require Win32API::File;
    }
}

has 'pgname';
has 'devmode';
has maxrotationsize => sub { 1048576 }; # 1 MiB

# override: https://docs.mojolicious.org/Mojo/Log#new
sub new {
    my $self = shift->SUPER::new(@_);

    my $pgname  = $self->pgname // 'LANraragi';
    my $devmode = $self->devmode ? 1 : 0;
    my $path    = $self->path;

    #Tell logger to store debug logs as well in debug mode
    if ($devmode) {
        $self->level('debug');
    }

    # Step down into trace if we're launched from npm run dev-server-verbose
    if ( $ENV{LRR_DEVSERVER} ) {
        $self->level('trace');
    }

    # Copy logged messages to STDOUT with the matching name
    $self->on(
        message => sub {
            my ( $log, $level, @lines ) = @_;

            # Like with logging to file, debug logs are only printed in debug mode
            unless ( $devmode == 0 && ( $level eq 'debug' || $level eq 'trace' ) ) {
                print "[$pgname] [$level] ";
                say $lines[0];
            }
        }
    );

    $self->format(
        sub {
            my ( $time, $level, @lines ) = @_;
            my $time2 = strftime( "%Y-%m-%d %H:%M:%S", localtime($time) );

            my $logstring = join( "\n", @lines );

            # We'd like to make sure we always show proper UTF-8.
            # redis_decode, while not initially designed for this, does the job.
            $logstring = redis_decode($logstring);

            return "[$time2] [$pgname] [$level] $logstring\n";
        }
    );

    return $self;
}

1;
