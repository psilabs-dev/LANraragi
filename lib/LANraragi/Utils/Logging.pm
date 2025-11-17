package LANraragi::Utils::Logging;

use strict;
use warnings;
use utf8;

use feature 'say';
use POSIX;
use FindBin;
use Time::HiRes;
use Config;

use Encode;
use File::ReadBackwards;
use Compress::Zlib;
use LANraragi::Model::Config;
use LANraragi::Utils::RotatingLog;
use LANraragi::Utils::Redis qw(redis_decode);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

# Contains all functions related to logging.
use Exporter 'import';
our @EXPORT_OK = qw(get_logger get_plugin_logger get_logdir get_lines_from_file);

BEGIN {
    if ( !IS_UNIX ) {
        require Win32API::File;
    }
}

our %LOGGER_CACHE;

# Get the Log folder.
sub get_logdir {

    my $log_folder = "$FindBin::Bin/../log";

    # Folder location can be overriden by LRR_LOG_DIRECTORY
    if ( $ENV{LRR_LOG_DIRECTORY} ) {
        $log_folder = $ENV{LRR_LOG_DIRECTORY};
    }
    mkdir $log_folder;
    return $log_folder;
}

# Returns a Logger object with a custom name and a filename for the log file.
sub get_logger {

    #Customize log file location and minimum log level
    my $pgname  = $_[0];
    my $logfile = $_[1];

    my $logpath     = get_logdir . "/$logfile.log";
    my $cache_key   = "$logfile|$pgname";
    my $log;

    # Reuse cached logger if exists
    if ( exists $LOGGER_CACHE{$cache_key} && -e $logpath && -s $logpath <= 1048576 ) {
        $log = $LOGGER_CACHE{$cache_key};

        eval {
            LANraragi::Utils::RotatingLog::refresh_handle($log);
            1;
        } or do {
            # handle cannot be refreshed; invalidate cache and serve normal logger
            delete $LOGGER_CACHE{$cache_key};
            $log = Mojo::Log->new(
                path    => $logpath,
                level   => 'info'
            );
            $log->error("RotatingLog cached handle refresh failed, falling back to Mojo::Log: $@");
        };

        return $log;
    }

    # Create and cache logger
    eval {
        $log = LANraragi::Utils::RotatingLog->new(
            path    => $logpath,
            logfile => $logfile,
            pgname  => $pgname,
            level   => 'info',
        );
        configure_logger( $log, $pgname );
        $LOGGER_CACHE{$cache_key} = $log;
        1;
    } or do {
        $log = Mojo::Log->new(
            path    => $logpath,
            level   => 'info'
        );
        configure_logger( $log, $pgname );
        $log->error("RotatingLog initialization failed, falling back to Mojo::Log: $@");
    };

    return $log;
}

sub get_plugin_logger {

    my ( $pkg, $filename, $line ) = caller;

    if ( !$pkg->can('plugin_info') ) {
        die "\"get_plugin_logger\" cannot be called from \"$pkg\"; line $line at $filename\n";
    }
    my %pi = $pkg->plugin_info();
    return get_logger( $pi{name}, "plugins" );
}

sub get_lines_from_file {

    my $lines = $_[0];
    my $file  = $_[1];

    #Load the last X lines of file
    if ( -e $file ) {
        my $bw  = File::ReadBackwards->new($file);
        my $res = "";
        for ( my $i = 0; $i <= $lines; $i++ ) {
            my $line = $bw->readline();
            if ($line) {
                $res = $line . $res;
            }

        }

        return decode_utf8($res);
    }

    return "No logs to be found here!";

}

# Provide logger with the required configs and formatting
sub configure_logger {

    my $logger  = shift;
    my $pgname  = shift;

    my $devmode = LANraragi::Model::Config->enable_devmode;

    #Tell logger to store debug logs as well in debug mode
    if ($devmode) {
        $logger->level('debug');
    }

    # Step down into trace if we're launched from npm run dev-server-verbose
    if ( $ENV{LRR_DEVSERVER} ) {
        $logger->level('trace');
    }

    # Copy logged messages to STDOUT with the matching name
    $logger->on(
        message => sub {
            my ( $log, $level, @lines ) = @_;

            # Like with logging to file, debug logs are only printed in debug mode
            unless ( $devmode == 0 && ( $level eq 'debug' || $level eq 'trace' ) ) {
                print "[$pgname] [$level] ";
                say $lines[0];
            }
        }
    );

    $logger->format(
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
}

1;
