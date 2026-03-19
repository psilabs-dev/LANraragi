package LANraragi::Model::PsilabsDev::Search;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgSearch',
        redis    => 'LANraragi::Model::Search',
    );
}

1;
