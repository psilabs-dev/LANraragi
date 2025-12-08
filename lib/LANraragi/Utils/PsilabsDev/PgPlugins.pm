package LANraragi::Utils::PsilabsDev::PgPlugins;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::Plugins qw(get_plugin get_plugin_parameters);
use LANraragi::Utils::Redis    qw(redis_decode);
use LANraragi::Utils::Logging  qw(get_logger);

use Exporter 'import';
our @EXPORT_OK = qw(use_plugin);

# replaces LANraragi::Utils::Plugins::use_plugin
# Shorthand method to use a plugin by name.
sub use_plugin {

    my ( $plugname, $id, $input ) = @_;

    my $plugin = get_plugin($plugname);
    my %plugin_result;
    my %pluginfo;

    if ( !$plugin ) {
        $plugin_result{error} = "Plugin not found on system.";
    } else {
        %pluginfo = $plugin->plugin_info();

        # Get the plugin settings in Redis (plugin settings are still in Redis)
        my %settings = get_plugin_parameters($plugname);
        $settings{oneshot} = $input;

        # Execute the plugin using Postgres implementations
        if ( $pluginfo{type} eq "script" ) {
            %plugin_result = LANraragi::Model::Plugins::exec_script_plugin( $plugin, %settings );
        } elsif ( $pluginfo{type} eq "metadata" ) {
            # Use Postgres implementation for metadata plugins
            require LANraragi::Model::PsilabsDev::PgPlugins;
            %plugin_result = LANraragi::Model::PsilabsDev::PgPlugins::exec_metadata_plugin( $plugin, $id, %settings );
        }

        # Decode the error value if there's one to avoid garbled characters
        if ( exists $plugin_result{error} ) {
            $plugin_result{error} = redis_decode( $plugin_result{error} );
        }
    }

    return ( \%pluginfo, \%plugin_result );
}

1;
