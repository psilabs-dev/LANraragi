package LANraragi::Model::PsilabsDev::Stats;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgStats',
        redis    => 'LANraragi::Model::Stats',
    );
}

1;
