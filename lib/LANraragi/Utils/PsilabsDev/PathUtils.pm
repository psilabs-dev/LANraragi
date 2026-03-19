package LANraragi::Utils::PsilabsDev::PathUtils;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_archive_path);

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Utils::PsilabsDev::PgPath',
        redis    => 'LANraragi::Utils::Path',
    );
}

1;
