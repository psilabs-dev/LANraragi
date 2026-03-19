package LANraragi::Utils::PsilabsDev::ArchiveUtils;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(extract_thumbnail extract_thumbnail_with_dbh delete_archive);

use LANraragi::Utils::PsilabsDev::Database qw(BACKEND);
use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Utils::PsilabsDev::PgArchive',
        redis    => 'LANraragi::Utils::Archive',
    );

    # delete_archive lives in Model::Archive on Redis, not Utils::Archive.
    if ( BACKEND eq 'redis' ) {
        require LANraragi::Model::Archive;
        no strict 'refs';
        *delete_archive = \&LANraragi::Model::Archive::delete_archive;
    }
}

1;
