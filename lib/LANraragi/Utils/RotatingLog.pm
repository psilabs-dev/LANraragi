package LANraragi::Utils::RotatingLog;

use strict;
use warnings;
use utf8;

use Fcntl qw(:flock O_CREAT O_RDWR);
use Compress::Zlib;
use Config;

use Mojo::Base 'Mojo::Log';
use Mojo::File;
use LANraragi::Model::Config;
use LANraragi::Utils::TempFolder qw(get_temp);

use Exporter 'import';
our @EXPORT_OK = qw(get_win32_fh);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

BEGIN {
    if ( !IS_UNIX ) {
        require Win32API::File;
    }
}

has 'logfile';

has counter => sub { 0 }; # number of logs emitted

# max number of archived logfiles to retain for log rotation (defaults to 7 files).
has retention_count => sub {
    my $count = 0 + ($ENV{LRR_LOGROTATE_FILES} // 7);
    die "retention_count must be positive" if $count < 1;
    return $count;
};

# max size of logfile (in bytes) before triggering rotation on next scan (defaults to 1 MB, min. 1kB).
has max_rotation_size => sub {
    my $size = 0 + ($ENV{LRR_LOGROTATE_SIZE} // 1048576);
    die "max_rotation_size must be greater than 1kb (1024)" if $size < 1024;
    return $size;
};

# Logfile lock path
has lockpath => sub {
    my $self        = shift;
    my $path        = $self->path;
    my $mf          = Mojo::File->new($path);
    my $base        = $mf->basename;
    my $lockpath    = get_temp . "/$base.lock";
    return $lockpath;
};

# File handle for logger's lock file
has lockfh => sub {
    my $self = shift;
    my $lockpath = $self->lockpath;
    open( my $fh, '>>', $lockpath ) or die "Could not open lockfile '$lockpath': $!";
    return $fh;
};

# override: https://docs.mojolicious.org/Mojo/Log#handle
has handle => sub {
    my $self = shift;
    my $path = $self->path;
    my $fh;
    eval {
        $fh = get_handle($path);
    } or die "Could not open logfile '$path': $!";
};

# https://perldoc.perl.org/perlobj#Destructors
# Clean everything up when logger is gone
sub DESTROY {
    my $self = shift;
    eval close $self->lockfh if defined $self->{lockfh};
    eval close $self->handle if defined $self->{handle};
}

# override: https://docs.mojolicious.org/Mojo/Log#append
# Includes logic which checks every 1k lines whether to rotate logs.
sub append {
    my ($self, $msg) = @_;

    $self->counter( $self->counter+1 );

    my $path   = $self->path;
    my $lockfh = $self->lockfh;

    # Acquire shared lock to serialize with rotation EX lock.
    flock( $lockfh, LOCK_SH ) or die "Failed to acquire shared log lock: $!";

    my $ret;
    eval {
        # Refresh handle if inode changed due to rotation from another process
        refresh_logger_handle($self);

        # every 1k lines, check size of path for log rotation
        if ( $self->counter % 1000 == 0 ) {
            maybe_rotate($self);
        }

        $ret = $self->SUPER::append($msg);
    };
    my $error = $@;
    flock( $lockfh, LOCK_UN );
    die $error if $error;

    return $ret;
}

# override: https://docs.mojolicious.org/Mojo/Log#new
# Inherits Mojo::Log to provide redis-locked log rotation during `new` and `append`,
# as well as prevention of log loss during concurrent append-time rotations with flock.
sub new {
    my $self = shift->SUPER::new(@_);

    my $path    = $self->path;
    my $logfile = $self->logfile;

    my $lockfh  = $self->lockfh;
    maybe_rotate($self);

    # handle logpath existence cases.
    # case 1 (logfile DNE):     create new logfile under exclusive lock
    # case 2 (logfile exist):   no action needed, just get the logfile handle
    if ( !-e $path ) {
        flock( $lockfh, LOCK_EX ) or die "Failed to acquire exclusive log lock: $!";
        my $logfile_create_error;
        eval {
            # Re-check inside lock in case another process created the file
            $self->handle;
            1;
        };
        $logfile_create_error = $@;
        flock( $lockfh, LOCK_UN );
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

# Rotate logfiles if conditions met, otherwise do nothing.
sub maybe_rotate {
    my $self    = shift;
    my $path    = $self->path;
    my $lockfh  = $self->lockfh;

    # Try to acquire a file lock between two rotation condition checks.
    if ( should_rotate($self, $path) ) {
        # flock( $lockfh, LOCK_UN );
        flock( $lockfh, LOCK_EX ) or die "Failed to acquire exclusive log lock: $!";

        my $rotation_error;
        if ( should_rotate($self, $path) ) {
            my $logfile = $self->logfile;
            eval {
                rotate_under_lock( $self );
                delete $self->{handle};
                $self->handle;
                1;
            } or do {
                my $lockpath = $self->lockpath;
                $rotation_error = "Failed to rotate logs during append-time under lock $lockpath: $@";
            };
            die $rotation_error if $rotation_error;
        }

        # Downgrade back to SH for the write
        flock( $lockfh, LOCK_UN );
        die $rotation_error if $rotation_error;
        flock( $lockfh, LOCK_SH ) or die "Failed to re-acquire shared log lock: $!";
    }
}

sub should_rotate {
    my $self = shift;
    my $path = $self->path;
    return -e $path && -s $path > $self->max_rotation_size;
}

# Do log rotation under Redis lock (flock provides assurance, but not sufficient to guard against rotation races)
# On redis connection error, skip rotation. Redis is assumed to be available, and temporary connection errors should not necessarily stop logging.
# Alternatively, we can ignore redis locking and continue rotate, risking flock race. Both events are highly unlikely.
sub rotate_under_lock {
    my $self            = shift;
    my $logpath         = $self->path;
    my $logfile         = $self->logfile;
    my $retention_count = $self->retention_count;

    my $lock_name       = "log-rotate:$logfile";
    my $redis_error;
    my $redis;
    my $lock;

    eval {
        $redis  = LANraragi::Model::Config->get_redis_config;
        $lock   = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );
    };
    if ( my $acquire_lock_error = $@ ) {
        $self->error("Failed to acquire redis lock; skipping rotation: $acquire_lock_error");
        return;
    }

    my $rotation_error;
    if ( $lock ) {
        eval {
            rotate_files( $logpath, $retention_count );
        } or do {
            $rotation_error = $@;
        };
        eval {
            $redis->del($lock_name);
        } or do {
            $self->error("Failed to release rotation lock: $@");
        };
    }

    eval {
        $redis->quit();
    } or do {
        $self->error("Failed to disconnect redis during rotation: $@");
    };
    die $rotation_error if $rotation_error;
}

# Do logfile rotation.
sub rotate_files {
    my $logpath         = shift;
    my $retention_count = shift;

    say "Rotating logpath $logpath";

    # Based on Logfile::Rotate
    # Rotate existing logs
    for ( my $i = $retention_count; $i > 1; $i-- ) {
        my $j = $i - 1;
        my $next = "$logpath.$i.gz";
        my $prev = "$logpath.$j.gz";
        if ( -r $prev && -f $prev ) {
            rename( $prev, $next ) or die "error: rename failed: ($prev,$next): $!";
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


# Refresh a logger's cached handle to prevent stale handles pointing to missing files.
sub refresh_logger_handle {
    my $logger = shift;

    if ( IS_UNIX ) {
        my $path            = $logger->path;
        my $cached_inode    = ( stat( $logger->handle ) )[1];
        my $path_inode      = ( stat( $path ) )[1];
        if ( !defined $cached_inode || !defined $path_inode || $cached_inode != $path_inode ) {
            close($logger->handle) if defined $logger->{handle};
            open( my $fh, '>>', $path ) or die "Could not open logfile '$path': $!";
            $logger->handle($fh);
        }
    } else {
        my $fh = get_win32_fh( $logger->path );
        $logger->handle($fh);
    }
}

sub get_handle {
    my $path = shift;
    # STDERR
    return \*STDERR unless $path;

    # File
    my $fh;
    if ( !IS_UNIX ) {
        $fh = get_win32_fh($path);
        return $fh if $fh;
    }

    # Fallback with default UTF-8 handle.
    $fh = Mojo::File->new($path)->open('>>');
    $fh->binmode(':encoding(UTF-8)');
    return $fh;
}

1;
