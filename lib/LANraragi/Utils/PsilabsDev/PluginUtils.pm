package LANraragi::Utils::PsilabsDev::PluginUtils;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(use_plugin);

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Utils::PsilabsDev::PgPlugins',
        redis    => 'LANraragi::Utils::Plugins',
    );
}

1;
