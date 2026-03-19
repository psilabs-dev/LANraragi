package LANraragi::Model::PsilabsDev::Plugins;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(exec_metadata_plugin exec_enabled_plugins_on_file);

use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgPlugins',
        redis    => 'LANraragi::Model::Plugins',
    );
}

1;
