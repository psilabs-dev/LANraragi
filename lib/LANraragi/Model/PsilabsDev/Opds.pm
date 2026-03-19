package LANraragi::Model::PsilabsDev::Opds;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgOpds',
        redis    => 'LANraragi::Model::Opds',
    );
}

1;
