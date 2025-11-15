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

1;
