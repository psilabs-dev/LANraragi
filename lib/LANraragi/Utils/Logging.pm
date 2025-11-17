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

# Ensure logfile created, and the mojo logger cached and returned, or die trying.
sub _ensure_logger {
    my $logpath     = $_[0];
    my $logfile     = $_[1];
    my $operation   = $_[2];
    my $cache_key   = $_[3];
    my $pgname      = $_[4];
    my $log;

    eval {
        $log = LANraragi::Utils::RotatingLog->new(
            path    => $logpath,
            logfile => $logfile,
            pgname  => $pgname,
            level   => 'info',
        );
        $log->handle;
        1;
    };

    if ( my $error = $@ ) {
        $log = Mojo::Log->new(
            path    => $logpath,
            level   => 'info',
        );
        $log->error("RotatingLog initialization failed, falling back to Mojo::Log ($operation): $error");
    }

    $LOGGER_CACHE{$cache_key} = $log;
    return $log;
}

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
        };

        return $log;
    }

    # Logfile lock owners have exclusive ability to create a logfile.
    # Non-owners may only append or wait for logfile availability.
    my $lock_name   = "log-rotate:$logfile";
    my $lock;

    if ( -e $logpath && -s $logpath > 1048576 ) {

        # Rotate log if it's > 1MB
        my $redis       = LANraragi::Model::Config->get_redis_config;
        $lock           = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );
        my $rotation_error;

        if ( $lock ) {
            eval {
                LANraragi::Utils::RotatingLog::rotate( $logpath );
                $log = LANraragi::Utils::RotatingLog->new(
                    path    => $logpath,
                    logfile => $logfile,
                    pgname  => $pgname,
                    level   => 'info',
                );
                $log->info("Rotated log files.");
                $LOGGER_CACHE{$cache_key} = $log;
                1;
            };

            $rotation_error = $@;
            $redis->del($lock_name);

        }

        $redis->quit();
        die $rotation_error if $rotation_error;

    }

    # handle logpath existence cases.
    # case 1 (logfile exist):                   no action needed, just get the logfile handle
    # case 2 (logfile DNE, lock not acquired):  wait 10s logfile to be available
    # case 3 (logfile DNE, lock acquired):      create new logfile
    if ( !-e $logpath ) {
        # handle cases where a logfile doesn't exist.

        my $redis       = LANraragi::Model::Config->get_redis_config;
        $lock           = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );

        my $logfile_create_error;
        if ( $lock ) {
            # This happens during start of app (if no logfile exists).
            say "Creating logfile $logfile.";
            eval {
                $log = LANraragi::Utils::RotatingLog->new(
                    path    => $logpath,
                    logfile => $logfile,
                    pgname  => $pgname,
                    level   => 'info',
                );
                $log->info("Created logfile.");
                $LOGGER_CACHE{$cache_key} = $log;
                1;
            };

            $logfile_create_error = $@;
            $redis->del($lock_name);
        } else {
            # Another worker is rotating/creating the logfile.
            my $tries       = 0;
            my $acquired    = 0;
            while ( $tries < 100 ) {
                if ( !-e $logpath ) {
                    Time::HiRes::sleep(0.1);
                    $tries++;
                } else {
                    eval {
                        $log = LANraragi::Utils::RotatingLog->new(
                            path    => $logpath,
                            logfile => $logfile,
                            pgname  => $pgname,
                            level   => 'info',
                        );
                        $log->handle;
                        $LOGGER_CACHE{$cache_key} = $log;
                        1;
                    };
                    $logfile_create_error   = $@;
                    $acquired               = 1;
                    last;
                }
            }
            if ( !$acquired ) {
                $logfile_create_error = "Timed out waiting for logfile to be created: $logpath";
            }
        }

        $redis->quit();
        die $logfile_create_error if $logfile_create_error;

    } else {
        eval {
            $log = LANraragi::Utils::RotatingLog->new(
                path    => $logpath,
                logfile => $logfile,
                pgname  => $pgname,
                level   => 'info',
            );
            $log->handle;
            $LOGGER_CACHE{$cache_key} = $log;
            1;
        };

        my $logfile_exist_error = $@;
        die $logfile_exist_error if $logfile_exist_error;
    }

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

1;
