package LANraragi::Utils::RotatingLog;

use strict;
use warnings;
use utf8;

use Fcntl qw(:flock);
use POSIX;
use Compress::Zlib;
use Config;

use Mojo::Base 'Mojo::Log';
use Mojo::Util      qw(encode);
use Mojo::File;
use LANraragi::Utils::Redis qw(redis_decode);
use LANraragi::Model::Config;

use Exporter 'import';
our @EXPORT_OK = qw(get_win32_fh);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

BEGIN {
    if ( !IS_UNIX ) {
        require Win32API::File;
    }
}

has 'pgname';
has 'devmode';
has 'init_error';       # initialization error

has maxrotationsize     => sub { 1048576 }; # 1 MiB
has counter             => sub { 0 };

# override: https://docs.mojolicious.org/Mojo/Log#handle
has handle => sub {
    my $self = shift;

    # STDERR
    return \*STDERR unless my $path = $self->path;

    # File
    if ( !IS_UNIX ) {
        my $fh = eval {
            get_win32_fh($path)
        };
        if ( my $error = $@ ) {
            $self->init_error($error);
        } else {
            return $fh if $fh;
        }
    }

    # Fallback with default handle.
    return Mojo::File->new($path)->open('>>');

};

# override: https://docs.mojolicious.org/Mojo/Log#append
# include logic which checks every 1k lines whether to rotate logs.
sub append {
    my ($self, $msg) = @_;

    $self->counter( $self->counter+1 );

    # every 1k lines, check size of path for log rotation
    if ( $self->counter % 1000 == 0 ) {
        return unless my $path = $self->path;
        if ( -s $path > $self->maxrotationsize ) {
            # TODO: do log rotation.
        }
    }

    return $self->SUPER::append($msg);
}

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

# Get perl file handler via Win32 native file handle of a logfile.
# https://perldoc.perl.org/Win32API::File#createFile
# https://perldoc.perl.org/Win32API::File#OsFHandleOpen
sub get_win32_fh {
    my $logfile = shift;
    my $h = Win32API::File::createFile( $logfile, "rw", "rwd" ) or die "createFile failed for $logfile; win32 says: $^E; errno: $!";
    local *FH;
    Win32API::File::OsFHandleOpen( *FH, $h, "a" ) or die "OsFHandleOpen failed for $logfile; $!";
    binmode *FH, ':encoding(UTF-8)';
    return *FH;
}

1;
