package LANraragi::Utils::RotatingLog;

use strict;
use warnings;
use utf8;

use Fcntl qw(:flock);
use Compress::Zlib;
use Config;

use Mojo::Base 'Mojo::Log';
use Mojo::File;
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

has retention_count     => sub { 0 + ($ENV{LRR_LOGROTATE_FILES} // 7) };        # max number of archived logfiles to retain for log rotation (defaults to 7 files).
has max_rotation_size   => sub { 0 + ($ENV{LRR_LOGROTATE_SIZE} // 1048576) };   # max size of logfile (in bytes) before triggering rotation on next scan (defaults to 1 MB).
has counter             => sub { 0 };
has lockpath            => sub {
    my $self = shift;
    my $path = $self->path;
    my $mf   = Mojo::File->new($path);
    my $dir  = $mf->dirname;
    my $real = $dir->realpath // $dir;
    my $base = $mf->basename;
    my $lockpath = Mojo::File->new($real, "$base.lock")->to_string;
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
# Includes logic which checks every 1k lines whether to rotate logs.
sub append {
    my ($self, $msg) = @_;

    $self->counter( $self->counter+1 );

    my $path   = $self->path;
    my $lockfh = $self->lockfh;

    # Acquire shared lock to serialize with rotation EX lock.
    flock( $lockfh, LOCK_SH ) or die "Failed to acquire shared log lock: $!";

    # Refresh handle if inode changed due to rotation from another process
    if ( IS_UNIX ) {
        my $cached_inode = ( stat( $self->handle ) )[1];
        my $path_inode   = ( stat( $path ) )[1];
        if ( !defined $cached_inode || !defined $path_inode || $cached_inode != $path_inode ) {
            open( my $fh, '>>', $path ) or die "Could not open logfile '$path': $!";
            $self->handle($fh);
        }
    } else {
        my $fh = get_win32_fh($path);
        $self->handle($fh);
    }

    # every 1k lines, check size of path for log rotation
    if ( $self->counter % 1000 == 0 ) {

        if ( -e $path && -s $path > $self->max_rotation_size ) {
            # Upgrade: release SH then acquire EX, re-check, rotate
            flock( $lockfh, LOCK_UN );
            flock( $lockfh, LOCK_EX ) or die "Failed to acquire exclusive log lock: $!";

            my $rotation_error;
            if ( -e $path && -s $path > $self->max_rotation_size ) {
                my $logfile = $self->logfile;
                eval {
                    rotate_under_lock( $path, $logfile, $self->retention_count );
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

    my $ret = $self->SUPER::append($msg);
    flock( $lockfh, LOCK_UN );
    return $ret;
}

# override: https://docs.mojolicious.org/Mojo/Log#new
# Inherits Mojo::Log to provide redis-locked log rotation during `new` and `append`,
# as well as prevention of log loss during concurrent append-time rotations with flock.
sub new {
    my $self = shift->SUPER::new(@_);

    my $path    = $self->path;
    my $logfile = $self->logfile;

    my $lockfh = $self->lockfh;

    if ( -e $path && -s $path > $self->max_rotation_size ) {

        flock( $lockfh, LOCK_EX ) or die "Failed to acquire exclusive log lock: $!";
        my $rotation_error;
        eval {
            rotate_under_lock( $path, $logfile, $self->retention_count );
            $self->handle;
            1;
        } or do {
            my $lockpath = $self->lockpath;
            $rotation_error = "Failed to rotate logs during init-time under lock $lockpath: $@";
        };
        die $rotation_error if $rotation_error;
        flock( $lockfh, LOCK_UN );

    }

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

# Do log rotation under Redis lock (flock is not sufficient to guard against rotation race conditions)
sub rotate_under_lock {
    my $logpath         = shift;
    my $logfile         = shift;
    my $retention_count = shift;

    my $lock_name       = "log-rotate:$logfile";
    my $redis           = LANraragi::Model::Config->get_redis_config;
    my $lock            = $redis->set( $lock_name, 1, 'NX', 'EX', 10 );
    my $rotation_error;

    if ( $lock ) {
        eval {
            rotate( $logpath, $retention_count );
        };

        $rotation_error = $@;
        $redis->del($lock_name);
    }

    $redis->quit();
    die $rotation_error if $rotation_error;
}

# Do log rotation.
sub rotate {
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

1;
