package LANraragi::Utils::PsilabsDev::PgDatabase;

use strict;
use warnings;
use utf8;

use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename;
use Cwd qw(getcwd);
use Redis;
use Time::HiRes qw(time);
use LANraragi::Model::Config;
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Tags qw(split_tags_to_array join_tags_to_string);
use LANraragi::Utils::String qw(trim trim_CRLF);
use List::MoreUtils qw(uniq);
use List::Util qw(max);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Path;
use LANraragi::Utils::PsilabsDev::PgPath qw(get_archive_path);
use LANraragi::Utils::PsilabsDev::PgArchive;
use LANraragi::Model::PsilabsDev::PgBackup;
use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Model::PsilabsDev::PgTankoubon;

# Functions for interacting with Postgres.
use Exporter 'import';
our @EXPORT_OK = qw(
  get_archive get_archive_json get_archive_json_multi set_tags set_tags_with_dbh set_title set_title_with_dbh set_summary set_summary_with_dbh set_isnew clear_new_all invalidate_cache clean_database clean_categories_and_tanks change_archive_id change_archive_id_with_dbh drop_database
);

# replaces LANraragi::Utils::Database::get_archive
# Retrieves archive metadata from Postgres and returns it as a hash
# similar to the Redis hgetall structure for compatibility
sub get_archive ($id) {
    my $logger = get_logger( "PgDatabase", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    eval {
        # Get archive data
        my $sth = $dbh->prepare(q{
            SELECT arcid, filename, title, summary, thumbhash
            FROM lrr_archive
            WHERE arcid = ?
        });
        $sth->execute($id);
        my $row = $sth->fetchrow_hashref;
        $sth->finish;

        unless ($row) {
            $dbh->disconnect();
            return ();
        }

        # Get tags as a comma-separated string
        my $tag_sth = $dbh->prepare(q{
            SELECT string_agg(
                CASE
                    WHEN t.namespace = '' THEN t.value
                    ELSE t.namespace || ':' || t.value
                END,
                ', '
            ) as tags
            FROM lrr_archive_to_tag_map atm
            JOIN lrr_tag t ON atm.tagid = t.tagid
            WHERE atm.arcid = ?
        });
        $tag_sth->execute($id);
        my $tag_row = $tag_sth->fetchrow_hashref;
        my $tags = $tag_row->{tags} // "";
        $tag_sth->finish;

        $dbh->disconnect();

        # Extract name from filename
        my ( $name, $path, $suffix ) = fileparse( $row->{filename}, qr/\.[^.]*/ );

        # Build hash compatible with Redis version
        my %hash = (
            name      => $name,
            title     => $row->{title} // "",
            tags      => $tags,
            summary   => $row->{summary} // "",
            file      => $row->{filename},
            thumbhash => $row->{thumbhash} // ""
        );

        return %hash;
    };

    if ( my $error = $@ ) {
        $logger->error("Error retrieving archive $id: $error");
        $dbh->disconnect();
        return ();
    }
}

# Internal function for building an archive JSON from Postgres data.
# This is similar to LANraragi::Utils::Database::build_json but does NOT apply
# redis_decode to text fields. Postgres data with client_encoding=UTF8 is already
# properly UTF-8 encoded, while Redis stores binary data that requires decoding.
# Applying redis_decode to already-decoded Postgres data causes double-decoding corruption.
sub build_json_pg ( $id, %hash ) {

    # Grab all metadata from the hash
    my ( $name, $title, $tags, $summary, $file, $isnew, $progress, $pagecount, $lastreadtime, $arcsize ) =
      @hash{qw(name title tags summary file isnew progress pagecount lastreadtime arcsize)};

    $file = LANraragi::Utils::Path::create_path($file);

    # Return undef if the file doesn't exist.
    return unless ( defined($file) && -e $file );

    # NOTE: Unlike Database::build_json, we do NOT call redis_decode here.
    # Postgres data is already UTF-8 encoded.

    # Workaround if title was incorrectly parsed as blank
    if ( !defined($title) || $title =~ /^\s*$/ ) {
        $title = $name;
    }

    my $arcdata = {
        arcid        => $id,
        title        => $title,
        filename     => $name,
        tags         => $tags,
        summary      => $summary,
        isnew        => $isnew ? $isnew : "false",
        extension    => lc( ( split( /\./, $file ) )[-1] ),
        progress     => $progress     ? int($progress)     : 0,
        pagecount    => $pagecount    ? int($pagecount)    : 0,
        lastreadtime => $lastreadtime ? int($lastreadtime) : 0,
        size         => $arcsize      ? int($arcsize)      : 0
    };

    return $arcdata;
}

# replaces LANraragi::Utils::Database::get_archive_json
# Builds a JSON object for an archive registered in the database and returns it.
sub get_archive_json ( $dbh, $id ) {
    my $logger = get_logger( "PgDatabase", "lanraragi" );

    my $arcdata;

    eval {
        # Check if this is a tank ID
        if ( $id =~ /^TANK/ ) {
            $arcdata = build_tank_json_pg($id);
        } else {
            # Check if archive exists
            my $check_sth = $dbh->prepare('SELECT arcid FROM lrr_archive WHERE arcid = ?');
            $check_sth->execute($id);
            my $exists = $check_sth->fetchrow_hashref;
            $check_sth->finish;

            die "Archive $id does not exist" unless $exists;

            # Get full archive data
            my $sth = $dbh->prepare(q{
                SELECT arcid, filename, title, summary, thumbhash, isnew, progress, pagecount, lastreadtime, arcsize
                FROM lrr_archive
                WHERE arcid = ?
            });
            $sth->execute($id);
            my $row = $sth->fetchrow_hashref;
            $sth->finish;

            # Get tags as a comma-separated string
            my $tag_sth = $dbh->prepare(q{
                SELECT string_agg(
                    CASE
                        WHEN t.namespace = '' THEN t.value
                        ELSE t.namespace || ':' || t.value
                    END,
                    ', '
                ) as tags
                FROM lrr_archive_to_tag_map atm
                JOIN lrr_tag t ON atm.tagid = t.tagid
                WHERE atm.arcid = ?
            });
            $tag_sth->execute($id);
            my $tag_row = $tag_sth->fetchrow_hashref;
            my $tags = $tag_row->{tags} // "";
            $tag_sth->finish;

            # Extract name from filename
            my ( $name, $path, $suffix ) = fileparse( $row->{filename}, qr/\.[^.]*/ );

            # Build hash for build_json_pg
            my %hash = (
                name         => $name,
                title        => $row->{title} // "",
                tags         => $tags,
                summary      => $row->{summary} // "",
                file         => $row->{filename},
                isnew        => $row->{isnew} ? "true" : "false",
                progress     => $row->{progress} // 0,
                pagecount    => $row->{pagecount} // 0,
                lastreadtime => $row->{lastreadtime} // 0,
                arcsize      => $row->{arcsize} // 0
            );

            # Use Postgres-specific build_json_pg which doesn't apply redis_decode
            $arcdata = build_json_pg( $id, %hash );
        }
    };

    if ( my $error = $@ ) {
        $logger->error("Error in get_archive_json for $id: $error");
        return;
    }

    return $arcdata;
}

# Internal helper for building a tank JSON (Postgres version).
# NOTE: Cannot directly reuse LANraragi::Utils::Database::build_tank_json because
# it calls LANraragi::Model::Tankoubon::get_tankoubon (Redis version) instead of
# LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon (Postgres version).
# The aggregation logic below is identical to Database::build_tank_json.
sub build_tank_json_pg ($id) {
    my ( $total, $count, %tank ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon( $id, 1 );

    # Aggregate data of all archives in the tank
    my $aggregate_tags      = "";
    my $aggregate_names     = "";
    my $aggregate_isnew     = 0;
    my $aggregate_progress  = 0;
    my $aggregate_pagecount = 0;
    my $latest_readtime     = 0;
    my $aggregate_size      = 0;

    foreach my $archive_info ( @{ $tank{full_data} } ) {
        $aggregate_tags  .= %$archive_info{tags} . ",";
        $aggregate_names .= %$archive_info{title} . ",";
        $aggregate_isnew     = $aggregate_isnew || %$archive_info{isnew};
        $aggregate_progress  = $aggregate_progress + %$archive_info{progress};
        $aggregate_pagecount = $aggregate_pagecount + %$archive_info{pagecount};
        $aggregate_size      = $aggregate_size + %$archive_info{size};
        $latest_readtime     = max( $latest_readtime, %$archive_info{lastreadtime} );
    }

    chop $aggregate_tags;
    chop $aggregate_names;

    my $arcdata = {
        arcid        => $id,
        title        => $tank{name},
        filename     => "",
        tags         => $aggregate_tags,
        summary      => "Tankoubon containing: $aggregate_names",
        isnew        => $aggregate_isnew ? $aggregate_isnew : "false",
        extension    => ".tank",
        progress     => $aggregate_progress,
        pagecount    => $aggregate_pagecount,
        lastreadtime => $latest_readtime,
        size         => $aggregate_size
    };

    return $arcdata;
}

# replaces LANraragi::Utils::Database::get_archive_json_multi
# Builds JSON objects for multiple archives and returns them as an array.
sub get_archive_json_multi (@ids) {
    my $logger = get_logger( "PgDatabase", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    my @archives;

    eval {
        # Return empty array if no IDs provided
        return unless @ids;

        # Separate tank IDs from archive IDs
        my @tank_ids;
        my @archive_ids;
        foreach my $id (@ids) {
            if ( $id =~ /^TANK/ ) {
                push @tank_ids, $id;
            } else {
                push @archive_ids, $id;
            }
        }

        # Process tank IDs individually (they require complex aggregation logic)
        if (@tank_ids) {
            my $tank_start = time();
            foreach my $tank_id (@tank_ids) {
                my $arcdata = build_tank_json_pg($tank_id);
                if ($arcdata) {
                    push @archives, $arcdata;
                }
            }
            my $tank_time = (time() - $tank_start) * 1000;
            $logger->debug(sprintf("[PERF] Tank JSON building: %.2fms (tank_count: %d)",
                $tank_time, scalar @tank_ids));
        }

        # Batch process archive IDs with a single query
        if (@archive_ids) {
            # Use batch query to fetch all archives and their tags at once
            my $query_start = time();
            my $placeholders = join(',', ('?') x @archive_ids);
            my $sth = $dbh->prepare(qq{
                SELECT a.arcid, a.filename, a.title, a.summary, a.thumbhash,
                       a.isnew, a.progress, a.pagecount, a.lastreadtime, a.arcsize,
                       COALESCE(string_agg(
                           CASE WHEN t.namespace = '' THEN t.value
                                ELSE t.namespace || ':' || t.value END,
                           ', '
                       ), '') as tags
                FROM lrr_archive a
                LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
                LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
                WHERE a.arcid IN ($placeholders)
                GROUP BY a.arcid, a.filename, a.title, a.summary, a.thumbhash,
                         a.isnew, a.progress, a.pagecount, a.lastreadtime, a.arcsize
            });
            $sth->execute(@archive_ids);

            # Store results in a hash for quick lookup
            my %archive_data;
            while (my $row = $sth->fetchrow_hashref) {
                # Extract name from filename
                my ( $name, $path, $suffix ) = fileparse( $row->{filename}, qr/\.[^.]*/ );

                # Build hash for build_json_pg
                my %hash = (
                    name         => $name,
                    title        => $row->{title} // "",
                    tags         => $row->{tags} // "",
                    summary      => $row->{summary} // "",
                    file         => $row->{filename},
                    isnew        => $row->{isnew} ? "true" : "false",
                    progress     => $row->{progress} // 0,
                    pagecount    => $row->{pagecount} // 0,
                    lastreadtime => $row->{lastreadtime} // 0,
                    arcsize      => $row->{arcsize} // 0
                );

                # Use Postgres-specific build_json_pg which doesn't apply redis_decode
                my $arcdata = build_json_pg( $row->{arcid}, %hash );
                if ($arcdata) {
                    $archive_data{$row->{arcid}} = $arcdata;
                }
            }
            $sth->finish;
            my $query_time = (time() - $query_start) * 1000;
            $logger->debug(sprintf("[PERF] Archive batch query execution: %.2fms (archive_count: %d)",
                $query_time, scalar @archive_ids));

            # Add archives to result array in the original order (preserving input order)
            my $transform_start = time();
            foreach my $id (@archive_ids) {
                if (exists $archive_data{$id}) {
                    push @archives, $archive_data{$id};
                }
            }
            my $transform_time = (time() - $transform_start) * 1000;
            $logger->debug(sprintf("[PERF] JSON transformation: %.2fms", $transform_time));
        }
    };

    if ( my $error = $@ ) {
        $logger->error("Error in get_archive_json_multi: $error");
    }

    $dbh->disconnect();
    return @archives;
}

# replaces LANraragi::Utils::Database::set_title
sub set_title ( $id, $newtitle ) {
    my $dbh = get_postgresql_dbh();
    $dbh->begin_work;

    eval {
        set_title_with_dbh( $dbh, $id, $newtitle );
    };

    my $error = $@;
    if ($error) {
        eval { $dbh->rollback };
        $dbh->disconnect;
        die $error;
    }

    $dbh->commit;
    $dbh->disconnect;
}

sub set_title_with_dbh ( $dbh, $id, $newtitle ) {

    my $logger = get_logger( "PgDatabase", "lanraragi" );

    if ( $newtitle ne "" ) {
        # NO begin_work - assume already in transaction

        # Update title in archive table
        my $sth = $dbh->prepare('UPDATE lrr_archive SET title = ? WHERE arcid = ?');
        $sth->execute($newtitle, $id);
        $sth->finish;

        # Update the search_tsv column for full-text search
        # The search_tsv includes arcid, title and tags, so we need to regenerate it
        my $update_tsv_sth = $dbh->prepare(q{
            UPDATE lrr_archive
            SET search_tsv = to_tsvector('simple',
                COALESCE(arcid, '') || ' ' ||
                COALESCE(title, '') || ' ' ||
                COALESCE(
                    (SELECT string_agg(COALESCE(t.namespace, '') || ':' || t.value, ' ')
                     FROM lrr_archive_to_tag_map atm
                     JOIN lrr_tag t ON atm.tagid = t.tagid
                     WHERE atm.arcid = lrr_archive.arcid),
                    ''
                )
            )
            WHERE arcid = ?
        });
        $update_tsv_sth->execute($id);
        $update_tsv_sth->finish;

        # NO commit - caller manages transaction

        $logger->debug("Updated title for archive $id to: $newtitle");
    }
}

# replaces LANraragi::Utils::Database::set_tags
# Set $tags for the archive with id $id.
# Set $append to 1 if you want to append the tags instead of replacing them.
sub set_tags ( $id, $newtags, $append = 0 ) {
    my $dbh = get_postgresql_dbh();
    $dbh->begin_work;

    eval {
        set_tags_with_dbh( $dbh, $id, $newtags, $append );
    };

    my $error = $@;
    if ($error) {
        eval { $dbh->rollback };
        $dbh->disconnect;
        die $error;
    }

    $dbh->commit;
    $dbh->disconnect;
}

sub set_tags_with_dbh ( $dbh, $id, $newtags, $append = 0 ) {

    my $logger = get_logger( "PgDatabase", "lanraragi" );

    # Get existing tags if we're appending
    my $oldtags = "";
    if ($append) {
        my $sth = $dbh->prepare(q{
            SELECT string_agg(
                CASE
                    WHEN t.namespace = '' THEN t.value
                    ELSE t.namespace || ':' || t.value
                END,
                ', '
            ) as tags
            FROM lrr_archive_to_tag_map atm
            JOIN lrr_tag t ON atm.tagid = t.tagid
            WHERE atm.arcid = ?
        });
        $sth->execute($id);
        my $row = $sth->fetchrow_hashref;
        $oldtags = $row->{tags} // "";
        $sth->finish;

        # If the new tags are empty, don't do anything
        unless ( length $newtags ) {
            return;
        }

        if ($oldtags) {
            $oldtags = trim($oldtags);
            if ( $oldtags ne "" ) {
                $newtags = $oldtags . "," . $newtags;
            }
        }
    }

    # Normalize tags: split, unique, rejoin
    $newtags = join_tags_to_string( uniq( split_tags_to_array($newtags) ) );

    $logger->debug("Setting tags for archive $id: $newtags");

    # NO begin_work - assume already in transaction

    # Remove existing tag mappings for this archive
    my $delete_sth = $dbh->prepare('DELETE FROM lrr_archive_to_tag_map WHERE arcid = ?');
    $delete_sth->execute($id);
    $delete_sth->finish;

    # Parse and insert new tags
    my @tag_array = split_tags_to_array($newtags);

    foreach my $tag (@tag_array) {
        next unless $tag;

        # Parse namespace and value
        my ($namespace, $value);
        if ( $tag =~ /^([^:]+):(.+)$/ ) {
            $namespace = $1;
            $value = $2;
        } else {
            $namespace = '';
            $value = $tag;
        }

        # Trim whitespace
        $namespace = trim($namespace);
        $value = trim($value);

        # Insert tag if it doesn't exist (ON CONFLICT DO NOTHING)
        my $tag_sth = $dbh->prepare(q{
            INSERT INTO lrr_tag (namespace, value)
            VALUES (?, ?)
            ON CONFLICT (namespace, value) DO NOTHING
        });
        $tag_sth->execute($namespace, $value);
        $tag_sth->finish;

        # Get the tag ID
        my $tagid_sth = $dbh->prepare(q{
            SELECT tagid FROM lrr_tag WHERE namespace = ? AND value = ?
        });
        $tagid_sth->execute($namespace, $value);
        my $row = $tagid_sth->fetchrow_hashref;
        my $tagid = $row->{tagid};
        $tagid_sth->finish;

        # Insert mapping
        my $map_sth = $dbh->prepare(q{
            INSERT INTO lrr_archive_to_tag_map (arcid, tagid, update_date)
            VALUES (?, ?, CURRENT_DATE)
        });
        $map_sth->execute($id, $tagid);
        $map_sth->finish;
    }

    # Update the search_tsv column for full-text search
    my $update_tsv_sth = $dbh->prepare(q{
        UPDATE lrr_archive
        SET search_tsv = to_tsvector('simple',
            COALESCE(arcid, '') || ' ' ||
            COALESCE(title, '') || ' ' ||
            COALESCE(
                (SELECT string_agg(COALESCE(t.namespace, '') || ':' || t.value, ' ')
                 FROM lrr_archive_to_tag_map atm
                 JOIN lrr_tag t ON atm.tagid = t.tagid
                 WHERE atm.arcid = lrr_archive.arcid),
                ''
            )
        )
        WHERE arcid = ?
    });
    $update_tsv_sth->execute($id);
    $update_tsv_sth->finish;

    # NO commit - caller manages transaction

    $logger->debug("Successfully updated tags for archive $id");

    # Postgres doesn't need a separate search cache like Redis
    # The search_tsv column is updated automatically above
}

# replaces LANraragi::Utils::Database::set_summary
sub set_summary ( $id, $summary ) {
    my $dbh = get_postgresql_dbh();
    $dbh->begin_work;

    eval {
        set_summary_with_dbh( $dbh, $id, $summary );
    };

    my $error = $@;
    if ($error) {
        eval { $dbh->rollback };
        $dbh->disconnect;
        die $error;
    }

    $dbh->commit;
    $dbh->disconnect;
}

sub set_summary_with_dbh ( $dbh, $id, $summary ) {

    my $logger = get_logger( "PgDatabase", "lanraragi" );

    eval {
        my $sth = $dbh->prepare('UPDATE lrr_archive SET summary = ? WHERE arcid = ?');
        $sth->execute($summary, $id);
        $sth->finish;

        $logger->debug("Updated summary for archive $id");
    };

    if ( my $error = $@ ) {
        $logger->error("Error setting summary for archive $id: $error");
        die $error;
    }
}

# replaces LANraragi::Utils::Database::set_isnew
sub set_isnew ( $id, $isnew ) {
    my $logger = get_logger( "PgDatabase", "lanraragi" );

    # Convert "false" to false boolean, everything else to true
    my $newval = $isnew ne "false" ? 1 : 0;

    my $dbh = get_postgresql_dbh();

    eval {
        my $sth = $dbh->prepare('UPDATE lrr_archive SET isnew = ? WHERE arcid = ?');
        $sth->execute($newval, $id);
        $sth->finish;

        $logger->debug("Updated isnew for archive $id to: $newval");
    };

    if ( my $error = $@ ) {
        $logger->error("Error setting isnew for archive $id: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();
}

# replaces LANraragi::Controller::Api::Database::clear_new_all (endpoint logic)
# Clear the new flag in all archives.
sub clear_new_all {
    my $logger = get_logger( "PgDatabase", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    eval {
        # Set isnew to false for all archives
        my $sth = $dbh->prepare('UPDATE lrr_archive SET isnew = FALSE');
        $sth->execute();
        my $rows_affected = $sth->rows;
        $sth->finish;

        $logger->info("Cleared new flag for all archives (affected $rows_affected rows)");
    };

    if ( my $error = $@ ) {
        $logger->error("Error clearing new flag for all archives: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();
}

# replaces LANraragi::Utils::Database::invalidate_cache
# In Postgres, there's no separate search cache to invalidate.
# The search_tsv column is kept in sync with updates, so this is a no-op.
sub invalidate_cache ( $rebuild_indexes = 0 ) {
    # No-op for Postgres - search index is always up to date via search_tsv
    # The $rebuild_indexes parameter is ignored as well
    return;
}

# replaces LANraragi::Utils::Database::change_archive_id
# Changes an archive's ID from $old_id to $new_id in the database.
# This updates the archive record and all references in categories and tankoubons.
# Also updates the filemap in Redis (still used by Shinobu for file tracking).
sub change_archive_id ( $old_id, $new_id ) {
    my $logger = get_logger( "PgDatabase", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    $logger->debug("Changing ID $old_id to $new_id");

    my $file_for_redis;
    eval {
        $dbh->begin_work;

        # Check if old ID exists in archive table
        my $check_sth = $dbh->prepare('SELECT arcid, filename FROM lrr_archive WHERE arcid = ?');
        $check_sth->execute($old_id);
        my $row = $check_sth->fetchrow_hashref;
        $check_sth->finish;

        if ($row) {
            # Update the archive ID
            my $update_arc_sth = $dbh->prepare('UPDATE lrr_archive SET arcid = ? WHERE arcid = ?');
            $update_arc_sth->execute($new_id, $old_id);
            $update_arc_sth->finish;

            # Update archive size based on file
            my $file = LANraragi::Utils::Path::create_path($row->{filename});
            if (defined($file) && -e $file) {
                my $arcsize = -s $file;
                my $update_size_sth = $dbh->prepare('UPDATE lrr_archive SET arcsize = ? WHERE arcid = ?');
                $update_size_sth->execute($arcsize, $new_id);
                $update_size_sth->finish;
            }

            # Update the search_tsv column with the new arcid
            # The search_tsv includes arcid, title and tags, so we need to regenerate it
            my $update_tsv_sth = $dbh->prepare(q{
                UPDATE lrr_archive
                SET search_tsv = to_tsvector('simple',
                    COALESCE(arcid, '') || ' ' ||
                    COALESCE(title, '') || ' ' ||
                    COALESCE(
                        (SELECT string_agg(COALESCE(t.namespace, '') || ':' || t.value, ' ')
                         FROM lrr_archive_to_tag_map atm
                         JOIN lrr_tag t ON atm.tagid = t.tagid
                         WHERE atm.arcid = lrr_archive.arcid),
                        ''
                    )
                )
                WHERE arcid = ?
            });
            $update_tsv_sth->execute($new_id);
            $update_tsv_sth->finish;

            # Update category mappings
            my $update_cat_sth = $dbh->prepare('UPDATE lrr_category_to_archive_map SET arcid = ? WHERE arcid = ?');
            $update_cat_sth->execute($new_id, $old_id);
            $update_cat_sth->finish;

            # Update tankoubon mappings
            my $update_tank_sth = $dbh->prepare('UPDATE lrr_tank_to_archive_map SET arcid = ? WHERE arcid = ?');
            $update_tank_sth->execute($new_id, $old_id);
            $update_tank_sth->finish;

            $logger->debug("Updated archive and all references from $old_id to $new_id");

            # Get file path for Redis update before committing
            $file_for_redis = get_archive_path($dbh, $new_id);
        }

        $dbh->commit;
    };

    if (my $error = $@) {
        $logger->error("Error changing archive ID from $old_id to $new_id: $error");
        eval { $dbh->rollback };
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    # Update the filemap in Redis (still used by Shinobu)
    if (defined($file_for_redis) && $file_for_redis ne "") {
        my $redis_config = LANraragi::Model::Config->get_redis_config;
        $redis_config->hset( "LRR_FILEMAP", $file_for_redis, $new_id );
        $redis_config->quit;
    }
}

# Cleans the database by clearing all categories, tankoubons, and their mappings.
# This is used before restoring from a backup.
# Note: Archives themselves are NOT deleted - only their metadata relationships.
sub clean_categories_and_tanks {
    my $logger = get_logger("PgDatabase", "lanraragi");
    my $dbh = get_postgresql_dbh();

    $logger->info("Cleaning categories and tankoubons before restore...");

    eval {
        $dbh->begin_work;

        # Delete category to archive mappings
        $dbh->do('DELETE FROM lrr_category_to_archive_map');
        $logger->debug("Cleared category to archive mappings");

        # Delete all categories
        $dbh->do('DELETE FROM lrr_category');
        $logger->debug("Cleared categories");

        # Delete tankoubon to archive mappings
        $dbh->do('DELETE FROM lrr_tank_to_archive_map');
        $logger->debug("Cleared tankoubon to archive mappings");

        # Delete all tankoubons
        $dbh->do('DELETE FROM lrr_tank');
        $logger->debug("Cleared tankoubons");

        $dbh->commit;
        $logger->info("Categories and tankoubons cleaned successfully");
    };

    if ($@) {
        my $error = $@;
        $logger->error("Error cleaning categories and tankoubons: $error");
        eval { $dbh->rollback };
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();
    return;
}

# Helper for change_archive_id that accepts a database handle
# Used internally by clean_database to avoid creating new connections mid-operation
sub change_archive_id_with_dbh ( $dbh, $old_id, $new_id ) {
    my $logger = get_logger( "PgDatabase", "lanraragi" );

    $logger->debug("Changing ID $old_id to $new_id");

    my $file_for_redis;

    # NO begin_work - assume already in transaction

    # Check if old ID exists in archive table
    my $check_sth = $dbh->prepare('SELECT arcid, filename FROM lrr_archive WHERE arcid = ?');
    $check_sth->execute($old_id);
    my $row = $check_sth->fetchrow_hashref;
    $check_sth->finish;

    if ($row) {
        # Update the archive ID
        my $update_arc_sth = $dbh->prepare('UPDATE lrr_archive SET arcid = ? WHERE arcid = ?');
        $update_arc_sth->execute($new_id, $old_id);
        $update_arc_sth->finish;

        # Update archive size based on file
        my $file = LANraragi::Utils::Path::create_path($row->{filename});
        if (defined($file) && -e $file) {
            my $arcsize = -s $file;
            my $update_size_sth = $dbh->prepare('UPDATE lrr_archive SET arcsize = ? WHERE arcid = ?');
            $update_size_sth->execute($arcsize, $new_id);
            $update_size_sth->finish;
        }

        # Update the search_tsv column with the new arcid
        # The search_tsv includes arcid, title and tags, so we need to regenerate it
        my $update_tsv_sth = $dbh->prepare(q{
            UPDATE lrr_archive
            SET search_tsv = to_tsvector('simple',
                COALESCE(arcid, '') || ' ' ||
                COALESCE(title, '') || ' ' ||
                COALESCE(
                    (SELECT string_agg(COALESCE(t.namespace, '') || ':' || t.value, ' ')
                     FROM lrr_archive_to_tag_map atm
                     JOIN lrr_tag t ON atm.tagid = t.tagid
                     WHERE atm.arcid = lrr_archive.arcid),
                    ''
                )
            )
            WHERE arcid = ?
        });
        $update_tsv_sth->execute($new_id);
        $update_tsv_sth->finish;

        # Update category mappings
        my $update_cat_sth = $dbh->prepare('UPDATE lrr_category_to_archive_map SET arcid = ? WHERE arcid = ?');
        $update_cat_sth->execute($new_id, $old_id);
        $update_cat_sth->finish;

        # Update tankoubon mappings
        my $update_tank_sth = $dbh->prepare('UPDATE lrr_tank_to_archive_map SET arcid = ? WHERE arcid = ?');
        $update_tank_sth->execute($new_id, $old_id);
        $update_tank_sth->finish;

        $logger->debug("Updated archive and all references from $old_id to $new_id");

        # Get file path for Redis update
        $file_for_redis = get_archive_path($dbh, $new_id);
    }

    # NO commit - caller manages transaction

    return $file_for_redis;
}

# replaces LANraragi::Utils::Database::clean_database
# Remove entries from the database that don't have a matching archive on the filesystem.
# Returns the number of entries deleted/unlinked.
sub clean_database {
    my $logger = get_logger("PgDatabase", "lanraragi");

    eval {
        # Save an autobackup somewhere before cleaning
        my $outfile = getcwd() . "/autobackup.json";
        $logger->info("Saving automatic backup to $outfile");
        open( my $fh, '>', $outfile );
        print $fh LANraragi::Model::PsilabsDev::PgBackup::build_backup_JSON();
        close $fh;
    };

    if ($@) {
        $logger->warn("Unable to open a file to save backup before cleaning database! $@");
    }

    # Get the filemap from Redis for ID checks later down the line
    # This is still needed because Shinobu uses Redis to track file changes
    my $redis_config = LANraragi::Model::Config->get_redis_config;
    my @filemapids = $redis_config->exists("LRR_FILEMAP") ? $redis_config->hvals("LRR_FILEMAP") : ();
    my %filemap    = map { $_ => 1 } @filemapids;

    my $dbh = get_postgresql_dbh();
    my $deleted_arcs  = 0;
    my $unlinked_arcs = 0;

    eval {
        # Get all archive IDs
        my $sql = 'SELECT arcid, filename FROM lrr_archive';
        my $sth = $dbh->prepare($sql);
        $sth->execute();

        while (my $row = $sth->fetchrow_hashref) {
            my $id = $row->{arcid};
            my $file = LANraragi::Utils::Path::create_path($row->{filename});

            # Check if the linked file exists
            unless ( defined($file) && -e $file ) {
                $logger->debug("Archive $id file does not exist: " . ($row->{filename} // "undefined"));

                # Delete the archive using PgArchive
                LANraragi::Utils::PsilabsDev::PgArchive::delete_archive($id);
                $deleted_arcs++;
                next;
            }

            # If the linked file exists, check if its ID is in the filemap
            # This handles cases where archive files are modified and get new IDs
            unless ( $file eq "" || exists $filemap{$id} ) {
                $logger->warn("File exists but its ID is no longer $id!");
                $logger->warn("Trying to find its new ID in the Shinobu filemap...");

                if ( $redis_config->hexists( "LRR_FILEMAP", $file ) ) {
                    my $newid = $redis_config->hget( "LRR_FILEMAP", $file );
                    $logger->warn("Found $newid in the filemap! Changing ID from $id to it.");

                    # Check if the new ID already exists as a separate entry
                    my $check_sth = $dbh->prepare('SELECT arcid FROM lrr_archive WHERE arcid = ?');
                    $check_sth->execute($newid);
                    my $exists = $check_sth->fetchrow_hashref;
                    $check_sth->finish;

                    if ( $exists ) {
                        $logger->warn("ID $newid already exists in the database! Unlinking old ID.");
                        # Clear the filename to unlink the old entry (with transaction)
                        eval {
                            $dbh->begin_work;
                            my $unlink_sth = $dbh->prepare('UPDATE lrr_archive SET filename = ? WHERE arcid = ?');
                            $unlink_sth->execute("", $id);
                            $unlink_sth->finish;
                            $dbh->commit;
                        };
                        if (my $err = $@) {
                            eval { $dbh->rollback };
                            die $err;
                        }
                        # NOTE: Do NOT increment $unlinked_arcs here, matching Redis behavior at line 381
                    } else {
                        # Use the transactional version of change_archive_id
                        my $file_for_redis;
                        eval {
                            $dbh->begin_work;
                            $file_for_redis = change_archive_id_with_dbh( $dbh, $id, $newid );
                            $dbh->commit;
                        };
                        if (my $err = $@) {
                            eval { $dbh->rollback };
                            die $err;
                        }
                        # Update Redis filemap
                        if (defined($file_for_redis) && $file_for_redis ne "") {
                            $redis_config->hset( "LRR_FILEMAP", $file_for_redis, $newid );
                        }
                    }

                } else {
                    $logger->warn("File $file not found in the filemap! Removing file reference in the database entry for $id.");
                    # Clear the filename to unlink the entry (with transaction)
                    eval {
                        $dbh->begin_work;
                        my $unlink_sth = $dbh->prepare('UPDATE lrr_archive SET filename = ? WHERE arcid = ?');
                        $unlink_sth->execute("", $id);
                        $unlink_sth->finish;
                        $dbh->commit;
                    };
                    if (my $err = $@) {
                        eval { $dbh->rollback };
                        die $err;
                    }
                    $unlinked_arcs++;
                }
            }
        }

        $sth->finish;
    };

    if (my $error = $@) {
        $logger->error("Error during clean_database: $error");
        $dbh->disconnect();
        $redis_config->quit;
        die $error;
    }

    $dbh->disconnect();
    $redis_config->quit;
    return ( $deleted_arcs, $unlinked_arcs );
}

# replaces LANraragi::Utils::Database::drop_database
# Drops the entire database by deleting all data from all tables.
# This is extremely dangerous and cannot be undone.
sub drop_database {
    my $logger = get_logger("PgDatabase", "lanraragi");
    my $dbh = get_postgresql_dbh();

    $logger->warn("Dropping entire database - all Postgres and Redis data will be lost!");

    # Drop Postgres tables
    eval {
        $dbh->begin_work;

        # Delete in order to respect foreign key constraints
        # First delete all mapping tables (they have foreign keys to other tables)
        $dbh->do('DELETE FROM lrr_archive_to_tag_map');
        $logger->debug("Cleared archive to tag mappings");

        $dbh->do('DELETE FROM lrr_category_to_archive_map');
        $logger->debug("Cleared category to archive mappings");

        $dbh->do('DELETE FROM lrr_tank_to_archive_map');
        $logger->debug("Cleared tankoubon to archive mappings");

        # Then delete the main tables
        $dbh->do('DELETE FROM lrr_tag');
        $logger->debug("Cleared tags");

        $dbh->do('DELETE FROM lrr_category');
        $logger->debug("Cleared categories");

        $dbh->do('DELETE FROM lrr_tank');
        $logger->debug("Cleared tankoubons");

        $dbh->do('DELETE FROM lrr_archive');
        $logger->debug("Cleared archives");

        $dbh->commit;
        $logger->info("Postgres database dropped successfully");
    };

    if (my $error = $@) {
        $logger->error("Error dropping Postgres database: $error");
        eval { $dbh->rollback };
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    # Drop all Redis databases (config, minion, search cache)
    # This matches the original behavior of flushall() in the Redis implementation
    my $redis;
    eval {
        $redis = LANraragi::Model::Config->get_redis;
        $redis->flushall();
        $logger->info("All Redis databases cleared successfully");
    };

    if (my $error = $@) {
        $logger->error("Error clearing Redis databases: $error");
        eval { $redis->quit if $redis };
        die $error;
    }

    $redis->quit();
}

1;
