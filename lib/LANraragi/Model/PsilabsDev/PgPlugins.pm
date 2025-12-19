package LANraragi::Model::PsilabsDev::PgPlugins;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;
use feature 'fc';

use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;

use LANraragi::Utils::String   qw(trim);
use LANraragi::Utils::PsilabsDev::PgDatabase qw(set_tags set_title set_summary set_tags_with_dbh set_title_with_dbh set_summary_with_dbh);
use LANraragi::Utils::PsilabsDev::PgArchive  qw(extract_thumbnail_with_dbh);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Tags     qw(rewrite_tags split_tags_to_array);
use LANraragi::Utils::Plugins  qw(get_plugin_parameters get_plugin);
use LANraragi::Utils::Path     qw(create_path);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);

# replaces LANraragi::Model::Plugins::exec_metadata_plugin
# Execute a specified plugin on a file, described through its archive ID.
sub exec_metadata_plugin ( $plugin, $id, %args ) {

    no warnings 'experimental::try';

    my $logger = get_logger( "Plugin System", "lanraragi" );

    if ( !$id ) {
        return ( error => "Tried to call a metadata plugin without providing an id." );
    }

    # Get archive metadata from Postgres instead of Redis
    my $dbh = get_postgresql_dbh();
    my $sth = $dbh->prepare(q{
        SELECT
            filename,
            title,
            COALESCE(
                (SELECT string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                )
                FROM lrr_archive_to_tag_map atm
                JOIN lrr_tag t ON atm.tagid = t.tagid
                WHERE atm.arcid = a.arcid),
                ''
            ) as tags,
            thumbhash
        FROM lrr_archive a
        WHERE arcid = ?
    });
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $dbh->disconnect;
        return ( error => "Archive with ID $id not found in database." );
    }

    my $name = $row->{filename} // "";
    my $title = $row->{title} // "";
    my $tags = $row->{tags} // "";
    my $thumbhash = $row->{thumbhash} // "";

    # Get file path from Postgres (filename column stores the full path)
    require LANraragi::Utils::PsilabsDev::PgPath;
    LANraragi::Utils::PsilabsDev::PgPath->import('get_archive_path');
    my $file = get_archive_path($dbh, $id);

    # If the thumbnail hash is empty or undefined, we'll generate it here.
    unless ( length $thumbhash ) {
        $logger->info("Thumbnail hash invalid, regenerating.");
        my $thumbdir = LANraragi::Model::Config->get_thumbdir;
        $thumbhash = "";

        try {
            extract_thumbnail_with_dbh( $dbh, $thumbdir, $id, 1, 1, 1 );

            # Re-fetch the thumbhash after generation
            my $hash_sth = $dbh->prepare('SELECT thumbhash FROM lrr_archive WHERE arcid = ?');
            $hash_sth->execute($id);
            my $hash_row = $hash_sth->fetchrow_hashref;
            $thumbhash = $hash_row->{thumbhash} // "";
            $hash_sth->finish;
        } catch ($e) {
            $logger->warn("Error building thumbnail: $e");
        }
    }

    $dbh->disconnect;

    my %returnhash;
    try {
        # Hand it off to the plugin here.
        # If the plugin requires a login, execute that first to get a UserAgent
        my %pluginfo = $plugin->plugin_info();
        my $ua = LANraragi::Model::Plugins::exec_login_plugin( $pluginfo{login_from} );

        # Bundle all the potentially interesting info in a hash
        my %infohash = (
            archive_id     => $id,
            archive_title  => $title,
            existing_tags  => $tags,
            thumbnail_hash => $thumbhash,
            file_path      => create_path( $file ),
            user_agent     => $ua,
            oneshot_param  => $args{'oneshot'}    # for old style plugins compatibility
        );

        my %newmetadata;

        if ( LANraragi::Model::Plugins::has_old_style_params(%args) ) {
            %newmetadata = $plugin->get_tags( \%infohash, @{ $args{customargs} } );
        } else {
            %newmetadata = $plugin->get_tags( \%infohash, \%args );
        }

        # Error checking
        if ( exists $newmetadata{error} ) {
            return %newmetadata;
        }

        my @tagarray = split_tags_to_array( $newmetadata{tags} );
        my $newtags  = "";

        # Process new metadata.
        if ( LANraragi::Model::Config->enable_tagrules ) {
            $logger->info("Applying tag rules...");
            my @rules = LANraragi::Utils::Database::get_computed_tagrules();
            @tagarray = rewrite_tags( \@tagarray, \@rules );
        }

        foreach my $tagtoadd (@tagarray) {

            # Only proceed if the tag isn't already in the existing tags
            unless ( index( uc($tags), uc($tagtoadd) ) != -1 ) {
                $newtags .= " $tagtoadd,";
            }
        }

        # Strip last comma and return processed tags in a hash
        chop($newtags);
        %returnhash = ( new_tags => $newtags );

        # Indicate a title change, if the plugin reports one
        if ( exists $newmetadata{title} && LANraragi::Model::Config->can_replacetitles ) {
            my $newtitle = $newmetadata{title};
            $newtitle = trim($newtitle);
            $returnhash{title} = $newtitle;
        }

        # Include updated summary data in response
        if ( exists $newmetadata{summary} ) {
            $returnhash{summary} = $newmetadata{summary};
        }

    } catch ($e) {
        return ( error => $e );
    }

    return %returnhash;
}

# replaces LANraragi::Model::Plugins::exec_enabled_plugins_on_file
# Sub used by Auto-Plugin.
sub exec_enabled_plugins_on_file ($id) {

    my $logger = get_logger( "Auto-Plugin", "lanraragi" );

    $logger->info("Executing enabled metadata plugins on archive with id $id.");

    my $successes = 0;
    my $failures  = 0;
    my $addedtags = 0;
    my $newtitle  = "";

    my @plugins = LANraragi::Utils::Plugins::get_enabled_plugins("metadata");

    # If the regex plugin is in the list, make sure it's ran first.
    # TODO: Make plugin exec order configurable
    foreach my $plugin (@plugins) {
        if ( $plugin->{namespace} eq "regexplugin" ) {
            my $regex_plugin = $plugin;

            # Remove element from array
            @plugins = grep { $_->{namespace} ne "regexplugin" } @plugins;
            unshift @plugins, $regex_plugin;
            last;
        }
    }

    foreach my $pluginfo (@plugins) {
        my $name   = $pluginfo->{namespace};
        my %args   = get_plugin_parameters($name);
        my $plugin = get_plugin($name);
        my %plugin_result;

        my %pluginfo = $plugin->plugin_info();

        %plugin_result = exec_metadata_plugin( $plugin, $id, %args );

        if ( exists $plugin_result{error} ) {
            $failures++;
            $logger->error( $plugin_result{error} );
            next;
        }

        $successes++;

        # Create shared database handle for this plugin's atomic updates
        my $dbh = get_postgresql_dbh();
        $dbh->begin_work;

        eval {
            # All metadata updates from this plugin in one transaction
            if ( $plugin_result{new_tags} ) {
                set_tags_with_dbh( $dbh, $id, $plugin_result{new_tags}, 1 );
            }

            if ( exists $plugin_result{title} ) {
                set_title_with_dbh( $dbh, $id, $plugin_result{title} );
                $newtitle = $plugin_result{title};
                $logger->debug("Changing title to $newtitle.");
            }

            if ( exists $plugin_result{summary} ) {
                set_summary_with_dbh( $dbh, $id, $plugin_result{summary} );
                $logger->debug("Summary has been changed.");
            }

            $dbh->commit;
        };

        if ( my $error = $@ ) {
            $logger->error("Error updating metadata for plugin $name: $error");
            eval { $dbh->rollback };
            $dbh->disconnect;
            $failures++;
            next;
        }

        $dbh->disconnect;

        # Sum up added tags
        my @added_tags = split( ',', $plugin_result{new_tags} );
        $addedtags += @added_tags;
    }

    return ( $successes, $failures, $addedtags, $newtitle );
}

1;
