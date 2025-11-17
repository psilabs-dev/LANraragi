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

has 'logfile';

has maxrotationsize     => sub { 1048576 }; # 1 MiB
has counter             => sub { 0 };

# override: https://docs.mojolicious.org/Mojo/Log#handle
has handle => sub {
    my $self = shift;

    # STDERR
    return \*STDERR unless my $path = $self->path;

    # File
    if ( !IS_UNIX ) {
        my $fh = get_win32_fh($path);
        return $fh if $fh;
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

        my $path = $self->path;
        if ( -s $path > $self->maxrotationsize && (my $logfile = $self->logfile) ) {
            my $lock_name   = "log-rotate:$logfile";
            my $redis       = LANraragi::Model::Config->get_redis_config;
            my $lock        = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );
            my $rotation_error;

            if ( $lock ) {
                eval {
                    rotate( $path );
                    delete $self->{handle};
                    $self->info("Rotated log files.");
                };
                $rotation_error = $@;
                $redis->del($lock_name);
            }

            $redis->quit();
            die $rotation_error if $rotation_error;
        }

    }

    return $self->SUPER::append($msg);
}

# override: https://docs.mojolicious.org/Mojo/Log#new
sub new {
    my $self = shift->SUPER::new(@_);

    my $path    = $self->path;
    my $logfile = $self->logfile;

    # Logfile lock owners have exclusive ability to create a logfile.
    # Non-owners may only append or wait for logfile availability.
    my $lock_name   = "log-rotate:$logfile";
    my $lock;

    if ( -e $path && -s $path > 1048576 ) {

        # Rotate log if it's > 1MB
        my $redis       = LANraragi::Model::Config->get_redis_config;
        $lock           = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );
        my $rotation_error;

        if ( $lock ) {
            eval {
                LANraragi::Utils::RotatingLog::rotate( $path );
                $self->info("Rotated log files.");
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
    if ( !-e $path ) {
        # handle cases where a logfile doesn't exist.

        my $redis       = LANraragi::Model::Config->get_redis_config;
        $lock           = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );

        my $logfile_create_error;
        if ( $lock ) {
            # This happens during start of app (if no logfile exists).
            say "Creating logfile $logfile.";
            eval {
                $self->info("Created logfile.");
                1;
            };

            $logfile_create_error = $@;
            $redis->del($lock_name);
        } else {
            # Another worker is rotating/creating the logfile.
            my $tries       = 0;
            my $acquired    = 0;
            while ( $tries < 100 ) {
                if ( !-e $path ) {
                    Time::HiRes::sleep(0.1);
                    $tries++;
                } else {
                    eval {
                        $self->handle;
                        1;
                    };
                    $logfile_create_error   = $@;
                    $acquired               = 1;
                    last;
                }
            }
            if ( !$acquired ) {
                $logfile_create_error = "Timed out waiting for logfile to be created: $path";
            }
        }

        $redis->quit();
        die $logfile_create_error if $logfile_create_error;

    } else {
        eval {
            $self->handle;
            1;
        };

        my $logfile_exist_error = $@;
        die $logfile_exist_error if $logfile_exist_error;
    }

    return $self;
}

# Get perl file handler via Win32 native file handle of a logfile.
# https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew
# https://perldoc.perl.org/Win32API::File#CreateFile
# https://perldoc.perl.org/Win32API::File#OsFHandleOpen
sub get_win32_fh {
    my $sPath    = shift;
    my $uAccess  = Win32API::File::FILE_APPEND_DATA();
    my $uShare   = Win32API::File::FILE_SHARE_READ()
        | Win32API::File::FILE_SHARE_WRITE()
        | Win32API::File::FILE_SHARE_DELETE();
    my $pSecAttr = [];
    my $uCreate  = Win32API::File::OPEN_ALWAYS();
    my $uFlags   = 0;
    my $hModel   = [];
    my $h = Win32API::File::CreateFile( $sPath, $uAccess, $uShare, $pSecAttr, $uCreate, $uFlags, $hModel )
        or die "CreateFile failed for $sPath; win32 says: $^E; errno: $!";

    local *FH;

    Win32API::File::OsFHandleOpen( *FH, $h, "w" ) or die "OsFHandleOpen failed for $sPath; $!";
    binmode *FH, ':encoding(UTF-8)';
    return *FH;
}

# Do log rotation.
sub rotate {
    my $logpath = shift;

    say "Rotating logpath $logpath";

    # Based on Logfile::Rotate
    # Rotate existing logs
    for ( my $i = 7; $i > 1; $i-- ) {
        my $j = $i - 1;
        my $next = "$logpath.$i.gz";
        my $prev = "$logpath.$j.gz";
        if ( -r $prev && -f $prev ) {
            rename( $prev, $next ) or die "error: rename failed: ($prev,$next)";
        }
    }

    # Move current logs to tempfile to stop new writes to it
    my $tmp = "$logpath.rotate";
    unlink $tmp if -e $tmp;
    rename( $logpath, $tmp ) or die "error: could not detach $logpath to $tmp: $!";

    # Gzip the detached tempfile
    my $gz = gzopen( "$logpath.1.gz", "wb" ) or die "error: could not gzopen $logpath.1.gz: $!";
    open( my $handle, '<', $tmp ) or die "Couldn't open $tmp: $!";
    my $buffer;
    $gz->gzwrite($buffer) while read( $handle, $buffer, 4096 ) > 0;
    $gz->gzclose();
    close $handle;
    unlink $tmp or die "error: could not delete $tmp: $!";
}

1;
