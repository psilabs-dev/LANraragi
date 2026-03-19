package LANraragi::Model::PsilabsDev::Tankoubon;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgTankoubon',
        redis    => 'LANraragi::Model::Tankoubon',
    );
}

1;
