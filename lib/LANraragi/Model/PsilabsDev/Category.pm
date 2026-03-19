package LANraragi::Model::PsilabsDev::Category;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgCategory',
        redis    => 'LANraragi::Model::Category',
    );
}

1;
