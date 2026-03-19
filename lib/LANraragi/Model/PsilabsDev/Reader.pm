package LANraragi::Model::PsilabsDev::Reader;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgReader',
        redis    => 'LANraragi::Model::Reader',
    );
}

1;
