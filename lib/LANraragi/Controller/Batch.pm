package LANraragi::Controller::Batch;
use Mojo::Base 'Mojolicious::Controller';

use Encode;
use Mojo::JSON qw(decode_json);

use LANraragi::Utils::Generic  qw(generate_themes_header exec_with_lock_pure);
use LANraragi::Utils::Tags     qw(rewrite_tags build_tag_replace_hash split_tags_to_array restore_CRLF);
use LANraragi::Utils::Database qw(get_computed_tagrules);
use LANraragi::Utils::PsilabsDev::PgDatabase qw(set_tags set_title set_summary set_tags_with_dbh set_title_with_dbh set_summary_with_dbh set_isnew invalidate_cache get_tags_string_with_dbh);
use LANraragi::Utils::Plugins  qw(get_plugins get_plugin get_plugin_parameters);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::PsilabsDev::Database qw(get_dbh);
use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Utils::PsilabsDev::PgArchive qw(delete_archive);
use LANraragi::Model::PsilabsDev::PgPlugins qw(exec_metadata_plugin);

# This action will render a template
sub index {
    my $self = shift;

    #Build plugin listing
    my @pluginlist = get_plugins("metadata");

    for ( my $i = 0; $i < scalar @pluginlist; $i++ ) {
        my $plugin = $pluginlist[$i];
        if ( ref( $plugin->{parameters} ) eq 'HASH' ) {
            my @params;
            foreach my $key ( sort keys %{ $plugin->{parameters} } ) {
                my $param = $plugin->{parameters}{$key};
                $param->{name} = $key;
                push( @params, $param );
            }
            $pluginlist[$i]->{parameters} = \@params;
        }
    }

    # Get static category list
    my @categories = LANraragi::Model::PsilabsDev::PgCategory::get_static_category_list();

    $self->render(
        template   => "batch",
        plugins    => \@pluginlist,
        title      => $self->LRR_CONF->get_htmltitle,
        descstr    => $self->LRR_DESC,
        csshead    => generate_themes_header($self),
        tagrules   => restore_CRLF( $self->LRR_CONF->get_tagrules ),
        categories => \@categories,
        version    => $self->LRR_VERSION
    );
}

# Websocket server receiving a list of IDs as a JSON and calling the specified plugin on them.
sub socket {

    my $self      = shift;
    my $cancelled = 0;
    my $client    = $self->tx;

    my $logger = get_logger( "Batch Tagging", "lanraragi" );

    $logger->info('Client connected to Batch Tagging service');

    # Increase inactivity timeout for connection a bit to account for clientside timeouts
    $self->inactivity_timeout(80);

    my @rules = get_computed_tagrules();
    my ( $rules, $hash_replace_rules ) = build_tag_replace_hash( \@rules );

    # Open database connection at WebSocket connection time (customs border)
    my $dbh = get_dbh();

    $self->on(
        message => sub {
            my ( $self, $msg ) = @_;

            $logger->debug("Received WS message $msg");

            # encode message before json-decoding it in case it has UTF8 characters in the argument overrides
            $msg = encode( 'UTF-8', $msg );
            $logger->trace("Encoded message $msg");

            # JSON-decode message and perform the requested action
            my $command    = decode_json($msg);
            my $operation  = $command->{'operation'};
            my $pluginname = $command->{"plugin"};
            my $id         = $command->{"archive"};

            unless ($id) {
                $client->finish( 1001 => 'No archives provided.' );
                return;
            }

            if ( $operation eq "plugin" ) {

                my $plugin = get_plugin($pluginname);
                unless ($plugin) {
                    $client->finish( 1001 => 'Plugin not found.' );
                    return;
                }

                # Global arguments can come from the database or the user override
                my @args_override = @{ $command->{"args"} };

                # get the saved defaults
                my %args = get_plugin_parameters($pluginname);
                if (@args_override) {

                    $logger->debug("Overriding configured parameters");
                    if ( exists $args{customargs} ) {

                        # User overrides from JSON are already properly decoded
                        $args{customargs} = \@args_override;
                    } else {
                        my @keys = sort grep { $_ !~ m/^enabled$/ } keys %args;
                        while ( my ( $idx, $key ) = each @keys ) {
                            $args{customargs}{$key} = $args_override[$idx];
                        }
                    }

                }

                # Send reply message for completed archive
                $client->send( { json => batch_plugin( $id, $plugin, %args ) } );
                return;
            }

            if ( $operation eq "clearnew" ) {
                set_isnew( $id, "false" );

                $client->send(
                    {   json => {
                            id      => $id,
                            success => 1,
                        }
                    }
                );
                return;
            }

            if ( $operation eq "addcat" ) {
                my $catid = $command->{"category"};
                my ( $catsucc, $caterr ) = LANraragi::Model::PsilabsDev::PgCategory::add_to_category( $catid, $id );

                $client->send(
                    {   json => {
                            id       => $id,
                            category => $catid,
                            success  => $catsucc,
                            message  => $caterr
                        }
                    }
                );
                return;
            }

            if ( $operation eq "tagrules" ) {

                $logger->debug("Applying tag rules to $id...");

                # Use WebSocket-level connection with explicit transaction
                eval {
                    $dbh->begin_work;

                    my $tags = get_tags_string_with_dbh($dbh, $id);

                    my @tagarray = split_tags_to_array($tags);
                    @tagarray = rewrite_tags( \@tagarray, $rules, $hash_replace_rules );

                    # Merge array with commas
                    my $newtags = join( ', ', @tagarray );
                    $logger->debug("New tags: $newtags");

                    # Use _with_dbh variant to share connection
                    set_tags_with_dbh( $dbh, $id, $newtags, 0 );

                    $dbh->commit;

                    $client->send(
                        {   json => {
                                id      => $id,
                                success => 1,
                                tags    => $newtags,
                            }
                        }
                    );

                    invalidate_cache();
                };

                if ( my $error = $@ ) {
                    eval { $dbh->rollback };
                    $logger->error("Failed to apply tag rules to $id: $error");
                    $client->send(
                        {   json => {
                                id      => $id,
                                success => 0,
                                message => "Failed to apply tag rules: $error"
                            }
                        }
                    );
                }

                return;
            }

            if ( $operation eq "delete" ) {
                $logger->debug("Deleting $id...");

                my $delStatus = delete_archive($id);

                $client->send(
                    {   json => {
                            id       => $id,
                            filename => $delStatus,
                            message  => $delStatus ? "Archive deleted." : "Archive not found.",
                            success  => $delStatus ? 1                  : 0
                        }
                    }
                );
                return;
            }

            # Unknown operation
            $client->send(
                {   json => {
                        id      => $id,
                        message => "Unknown operation type $operation.",
                        success => 0
                    }
                }
            );
        }
    );

    $self->on(

        # If the client doesn't respond, halt processing
        finish => sub {
            $logger->info('Client disconnected, halting remaining operations');
            $cancelled = 1;

            # Clean up on WebSocket close
            $dbh->disconnect if $dbh;
        }
    );

}

sub batch_plugin {
    my ( $id, $plugin, %args ) = @_;

    # Run plugin with args on id
    my %plugin_result = exec_metadata_plugin( $plugin, $id, %args );

    # If the plugin exec returned tags, add them
    unless ( exists $plugin_result{error} ) {
        # Wrap all metadata updates in a single transaction for atomicity
        my $dbh = get_dbh();
        $dbh->begin_work;

        eval {
            # All metadata updates from this plugin in one transaction
            if ( $plugin_result{new_tags} ) {
                set_tags_with_dbh( $dbh, $id, $plugin_result{new_tags}, 1 );
            }

            if ( exists $plugin_result{title} ) {
                set_title_with_dbh( $dbh, $id, $plugin_result{title} );
            }

            if ( exists $plugin_result{summary} ) {
                set_summary_with_dbh( $dbh, $id, $plugin_result{summary} );
            }

            $dbh->commit;
        };

        if ( my $error = $@ ) {
            eval { $dbh->rollback };
            $dbh->disconnect;
            die $error;
        }

        $dbh->disconnect;
    }

    return {
        id      => $id,
        success => exists $plugin_result{error} ? 0 : 1,
        message => $plugin_result{error},
        tags    => $plugin_result{new_tags},
        title   => exists $plugin_result{title} ? $plugin_result{title} : ""
    };
}

1;
