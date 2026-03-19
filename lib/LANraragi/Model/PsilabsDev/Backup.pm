package LANraragi::Model::PsilabsDev::Backup;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgBackup',
        redis    => 'LANraragi::Model::Backup',
    );
}

1;
