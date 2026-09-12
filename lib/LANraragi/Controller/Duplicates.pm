package LANraragi::Controller::Duplicates;
use Mojo::Base 'Mojolicious::Controller';
use utf8;
use POSIX qw(strftime);

use Mojo::JSON qw(decode_json encode_json);

use LANraragi::Utils::Generic  qw(generate_themes_header);
use LANraragi::Utils::PsilabsDev::Database qw(get_dbh);
use LANraragi::Utils::PsilabsDev::PgDatabase qw(get_archive_summary_with_dbh);
use LANraragi::Model::Config;

# Go through the archives in the content directory and build the template at the end.
sub index {

    my $self = shift;

    if ( $self->req->param('delete') ) {
        $self->LRR_LOGGER->debug("Cleared all detected duplicates!");
        eval {
            my $redis = LANraragi::Model::Config->get_redis_config;
            $redis->del("LRR_DUPLICATE_GROUPS");
            $redis->quit();
        };
        if (my $error = $@) {
            $self->LRR_LOGGER->error("Error clearing duplicate groups: $error");
        }
    }

    my %duplicate_groups;
    eval {
        my $redis = LANraragi::Model::Config->get_redis_config;
        if ( $redis->exists("LRR_DUPLICATE_GROUPS") ) {
            %duplicate_groups = $redis->hgetall("LRR_DUPLICATE_GROUPS");
        }
        $redis->quit();
    };
    if (my $error = $@) {
        $self->LRR_LOGGER->error("Error fetching duplicate groups: $error");
    }

    my @duplicates;

    my $dbh;
    eval {
        $dbh = get_dbh();

        foreach my $key ( keys %duplicate_groups ) {

            # Decode the JSON-encoded array of IDs
            my $deserialized = decode_json( $duplicate_groups{$key} );
            my @ids          = @{$deserialized};

            my @archives;
            foreach my $id (@ids) {
                my $row = get_archive_summary_with_dbh($dbh, $id);

                # Check if archive still exists
                if ($row) {
                    my %archive;
                    $archive{'arcid'}     = $id;
                    $archive{'group_key'} = $key;
                    $archive{'name'}      = $row->{filename};
                    $archive{'title'}     = $row->{title} // "";
                    $archive{'tags'}      = $row->{tags} // "";

                    if ( $archive{'tags'} =~ /date_added:(\d+)/ ) {
                        $archive{'date_added'} = strftime( "%Y-%m-%d %H:%M:%S", localtime($1) );
                    }

                    push @archives, \%archive;
                } else {

                    # if dup size of group less than 2, its not a group anymore
                    if ( scalar @ids <= 2 ) {
                        my $size = scalar @ids;
                        $self->LRR_LOGGER->debug("group $key: too small ($size) - removing key");
                        eval {
                            my $redis = LANraragi::Model::Config->get_redis_config;
                            $redis->hdel( "LRR_DUPLICATE_GROUPS", $key );
                            $redis->quit();
                        };
                        if (my $error = $@) {
                            $self->LRR_LOGGER->error("Error deleting duplicate group $key: $error");
                        }
                    } else {

                        # archive vanished -> remove from dupes
                        @ids = grep { $_ ne $id } @ids;
                        $self->LRR_LOGGER->debug("group $key: archive $id vanished - removing from group");
                        eval {
                            my $redis = LANraragi::Model::Config->get_redis_config;
                            $redis->hset( "LRR_DUPLICATE_GROUPS", $key, encode_json( \@ids ) );
                            $redis->quit();
                        };
                        if (my $error = $@) {
                            $self->LRR_LOGGER->error("Error updating duplicate group $key: $error");
                        }
                    }
                }
            }
            push @duplicates, \@archives;
        }

        $dbh->disconnect();
    };
    if ( my $error = $@ ) {
        $self->LRR_LOGGER->error("Database error in duplicates endpoint: $error");
        $dbh->disconnect() if $dbh;
    }

    $self->render(
        template   => "duplicates",
        title      => $self->LRR_CONF->get_htmltitle,
        duplicates => \@duplicates,
        csshead    => generate_themes_header($self)
    );
}

1;
