package LANraragi::Model::PsilabsDev::PgTankoubon;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::Database qw(get_dbh);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Model::Config;

# replaces LANraragi::Model::Tankoubon::get_tankoubon_list
# get_tankoubon_list(page)
#   Returns a list of all the Tankoubon objects.
sub get_tankoubon_list {
    my $page = shift // 0;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();

    # Get all tankoubons
    my $tank_sql = <<'SQL';
        SELECT tankid, name, summary, tags
        FROM lrr_tank
        ORDER BY tankid
SQL

    my $tank_sth = $dbh->prepare($tank_sql);
    $tank_sth->execute();

    # Prepare archive query ONCE outside the loop
    my $arc_sql = <<'SQL';
        SELECT arcid
        FROM lrr_tank_to_archive_map
        WHERE tankid = ?
        ORDER BY position
SQL
    my $arc_sth = $dbh->prepare($arc_sql);

    my @result;

    while (my $tank_row = $tank_sth->fetchrow_hashref) {
        my $tankid = $tank_row->{tankid};

        # Execute the prepared statement for this tankoubon
        $arc_sth->execute($tankid);

        my @archives;
        while (my $arc_row = $arc_sth->fetchrow_hashref) {
            push @archives, $arc_row->{arcid};
        }

        # Build tankoubon hash matching Redis implementation format
        my %tankoubon = (
            id       => $tankid,
            name     => $tank_row->{name},
            summary  => $tank_row->{summary} // '',
            tags     => $tank_row->{tags} // '',
            archives => \@archives
        );

        push @result, \%tankoubon;
    }
    $tank_sth->finish;
    $arc_sth->finish;

    $dbh->disconnect();

    my $total = scalar(@result);

    # Handle pagination
    if ($page < 0) {
        # Return all results
        return ($total, $total, @result);
    } else {
        # Get page size from config
        my $keysperpage = LANraragi::Model::Config->get_pagesize;

        my $start = $page * $keysperpage;
        my $end = $start + $keysperpage - 1;

        if ($end > $#result) {
            $end = $#result;
        }

        if ($start > $#result) {
            # No results for this page
            return ($total, $total);
        }

        my @page_results = @result[$start .. $end];
        return ($total, $total, @page_results);
    }
}

# replaces: LANraragi::Model::Tankoubon::create_tankoubon
# create_tankoubon(name, existing_id)
#   Create a Tankoubon.
#   If an existing Tankoubon ID is supplied, said Tankoubon will be updated with the given parameters.
#   Returns the ID of the created/updated Tankoubon.
sub create_tankoubon {
    my ( $name, $tank_id ) = @_;
    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();

    # Set all fields of the tank object
    unless ( length($tank_id) ) {
        $tank_id = "TANK_" . time();

        my $isnewkey = 0;
        # Prepare statement once before loop
        my $check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
        until ($isnewkey) {
            # Check if the tank ID exists, move timestamp further if it does
            $check_sth->execute($tank_id);
            my $exists = $check_sth->fetchrow_hashref;

            if ($exists) {
                $tank_id = "TANK_" . ( time() + 1 );
            } else {
                $isnewkey = 1;
            }
        }
        $check_sth->finish;
    }

    # Check if tank exists
    my $exists_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
    $exists_sth->execute($tank_id);
    my $existing = $exists_sth->fetchrow_hashref;
    $exists_sth->finish;

    if ($existing) {
        # Update existing tank
        my $update_sth = $dbh->prepare(
            'UPDATE lrr_tank SET name = ? WHERE tankid = ?'
        );
        $update_sth->execute($name, $tank_id);
        $update_sth->finish;
        $logger->debug("Updated tankoubon $tank_id");
    } else {
        # Insert new tank with default values
        my $insert_sth = $dbh->prepare(
            'INSERT INTO lrr_tank (tankid, name, summary, tags) VALUES (?, ?, ?, ?)'
        );
        $insert_sth->execute($tank_id, $name, '', '');
        $insert_sth->finish;
        $logger->debug("Created new tankoubon $tank_id");
    }

    $dbh->disconnect();
    return $tank_id;
}

# replaces: LANraragi::Model::Tankoubon::get_tankoubon
# get_tankoubon(tankoubonid, fulldata, page)
#   Returns the Tankoubon matching the given id.
#   Returns undef if the id doesn't exist.
sub get_tankoubon {
    my ( $tank_id, $fulldata, $page ) = @_;

    $fulldata //= 0;
    $page //= 0;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();

    if ( $tank_id eq "" ) {
        $logger->debug("No Tankoubon ID provided.");
        $dbh->disconnect();
        return ();
    }

    # Check if tank exists and get metadata
    my $tank_sql = 'SELECT tankid, name, summary, tags FROM lrr_tank WHERE tankid = ?';
    my $tank_sth = $dbh->prepare($tank_sql);
    $tank_sth->execute($tank_id);
    my $tank_row = $tank_sth->fetchrow_hashref;
    $tank_sth->finish;

    unless ($tank_row) {
        $logger->warn("$tank_id doesn't exist in the database!");
        $dbh->disconnect();
        return ();
    }

    # Build base metadata hash
    my %tank = (
        id      => $tank_id,
        name    => $tank_row->{name},
        summary => $tank_row->{summary} // '',
        tags    => $tank_row->{tags} // ''
    );

    # Get total count of archives in this tankoubon
    my $count_sql = 'SELECT COUNT(*) as total FROM lrr_tank_to_archive_map WHERE tankid = ?';
    my $count_sth = $dbh->prepare($count_sql);
    $count_sth->execute($tank_id);
    my $count_row = $count_sth->fetchrow_hashref;
    my $total = $count_row->{total} || 0;
    $count_sth->finish;

    # Fetch archives with pagination
    my @archives;
    my $arc_sql;
    my $arc_sth;

    if ( $page < 0 ) {
        # Get all archives
        $arc_sql = 'SELECT arcid FROM lrr_tank_to_archive_map WHERE tankid = ? ORDER BY position';
        $arc_sth = $dbh->prepare($arc_sql);
        $arc_sth->execute($tank_id);
    } else {
        # Get paginated archives
        my $keysperpage = LANraragi::Model::Config->get_pagesize;
        my $offset = $page * $keysperpage;

        $arc_sql = 'SELECT arcid FROM lrr_tank_to_archive_map WHERE tankid = ? ORDER BY position LIMIT ? OFFSET ?';
        $arc_sth = $dbh->prepare($arc_sql);
        $arc_sth->execute($tank_id, $keysperpage, $offset);
    }

    while (my $arc_row = $arc_sth->fetchrow_hashref) {
        push @archives, $arc_row->{arcid};
    }
    $arc_sth->finish;

    # If fulldata is requested, fetch complete archive information
    if ($fulldata) {
        my @full_data;

        # Batch query optimization: fetch all archive data in a single query
        if (@archives) {
            my $placeholders = join(',', ('?') x @archives);
            my $batch_sql = qq{
                SELECT
                    a.arcid,
                    a.filename,
                    a.title,
                    a.summary,
                    a.isnew,
                    a.progress,
                    a.pagecount,
                    a.lastreadtime,
                    a.arcsize,
                    a.extension,
                    COALESCE(
                        string_agg(
                            CASE
                                WHEN t.namespace = '' THEN t.value
                                ELSE t.namespace || ':' || t.value
                            END,
                            ', '
                        ),
                        ''
                    ) as tags
                FROM lrr_archive a
                LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
                LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
                WHERE a.arcid IN ($placeholders)
                GROUP BY a.arcid, a.filename, a.title, a.summary, a.isnew,
                         a.progress, a.pagecount, a.lastreadtime, a.arcsize, a.extension
            };

            my $batch_sth = $dbh->prepare($batch_sql);
            $batch_sth->execute(@archives);

            # Build hash map of results keyed by arcid
            my %archive_data;
            while (my $arc_row = $batch_sth->fetchrow_hashref) {
                $archive_data{$arc_row->{arcid}} = $arc_row;
            }
            $batch_sth->finish;

            # Build response in original order, preserving tankoubon sequence
            foreach my $arc_id (@archives) {
                if (exists $archive_data{$arc_id}) {
                    my $arc_row = $archive_data{$arc_id};

                    # Check if the file exists on disk (matching Redis behavior)
                    my $filename = $arc_row->{filename};
                    next unless (defined($filename) && -e $filename);

                    # Handle whitespace-only title
                    my $title = $arc_row->{title};
                    if ( !defined($title) || $title =~ /^\s*$/ ) {
                        $title = $arc_row->{filename};
                    }

                    my $arcdata = {
                        arcid        => $arc_row->{arcid},
                        title        => $title,
                        filename     => $arc_row->{filename},
                        tags         => $arc_row->{tags} // '',
                        summary      => $arc_row->{summary} // '',
                        isnew        => $arc_row->{isnew} ? 'true' : 'false',
                        extension    => $arc_row->{extension} // '',
                        progress     => $arc_row->{progress} ? int($arc_row->{progress}) : 0,
                        pagecount    => $arc_row->{pagecount} ? int($arc_row->{pagecount}) : 0,
                        lastreadtime => $arc_row->{lastreadtime} ? int($arc_row->{lastreadtime}) : 0,
                        size         => $arc_row->{arcsize} ? int($arc_row->{arcsize}) : 0
                    };

                    push @full_data, $arcdata;
                }
                # If archive doesn't exist in results, gracefully skip it (missing archive)
            }
        }

        $tank{archives} = \@archives;
        $tank{full_data} = \@full_data;
    } else {
        $tank{archives} = \@archives;
    }

    $dbh->disconnect();

    my $filtered = scalar(@archives);
    return ( $total, $filtered, %tank );
}

# replaces: LANraragi::Model::Tankoubon::update_metadata
# update_metadata(tankoubonid, data)
#   Updates the metadata in the Tankoubon.
#   Returns 1 on success, 0 on failure alongside an error message.
sub update_metadata {
    my ( $tank_id, $data ) = @_;

    if ( not defined $data->{"metadata"} ) {
        return ( 1, "" );
    }

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();
    my $err = "";
    my $name    = $data->{"metadata"}->{"name"}    || undef;
    my $summary = exists $data->{"metadata"}->{"summary"} ? $data->{"metadata"}->{"summary"} : undef;
    my $tags    = exists $data->{"metadata"}->{"tags"}    ? $data->{"metadata"}->{"tags"}    : undef;

    # Check if tank exists
    my $tank_check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
    $tank_check_sth->execute($tank_id);
    my $tank_exists = $tank_check_sth->fetchrow_hashref;
    $tank_check_sth->finish;

    unless ($tank_exists) {
        $err = "$tank_id doesn't exist in the database!";
        $logger->warn($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    # Build dynamic UPDATE statement
    my @set_clauses;
    my @values;

    if ( defined $name ) {
        push @set_clauses, "name = ?";
        push @values, $name;
    }

    if ( defined $summary ) {
        push @set_clauses, "summary = ?";
        push @values, $summary;
    }

    if ( defined $tags ) {
        push @set_clauses, "tags = ?";
        push @values, $tags;
    }

    if ( @set_clauses ) {
        my $update_sql = "UPDATE lrr_tank SET " . join(", ", @set_clauses) . " WHERE tankid = ?";
        push @values, $tank_id;

        my $update_sth = $dbh->prepare($update_sql);
        $update_sth->execute(@values);
        $update_sth->finish;
        $logger->debug("Updated metadata for tankoubon $tank_id");
    }

    $dbh->disconnect();
    return ( 1, $err );
}

# replaces: LANraragi::Model::Tankoubon::update_archive_list
# update_archive_list(tankoubonid, data)
#   Updates the archives list in a Tankoubon.
#   Returns 1 on success, 0 on failure alongside an error message.
sub update_archive_list {
    my ( $tank_id, $data ) = @_;

    if ( not defined $data->{"archives"} ) {
        return ( 1, "" );
    }

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();
    my $err = "";
    my @tank_archives = @{ $data->{"archives"} };

    # Check if tank exists
    my $tank_check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
    $tank_check_sth->execute($tank_id);
    my $tank_exists = $tank_check_sth->fetchrow_hashref;
    $tank_check_sth->finish;

    unless ($tank_exists) {
        $err = "$tank_id doesn't exist in the database!";
        $logger->warn($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    # Verify all archives exist
    my $arc_check_sth = $dbh->prepare('SELECT arcid FROM lrr_archive WHERE arcid = ?');
    foreach my $arc_id (@tank_archives) {
        $arc_check_sth->execute($arc_id);
        my $arc_exists = $arc_check_sth->fetchrow_hashref;

        unless ($arc_exists) {
            $err = "$arc_id does not exist in the database.";
            $logger->error($err);
            $arc_check_sth->finish;
            $dbh->disconnect();
            return ( 0, $err );
        }
    }
    $arc_check_sth->finish;

    # Begin transaction
    $dbh->begin_work;

    eval {
        # Delete all existing archive mappings for this tank
        my $delete_sth = $dbh->prepare('DELETE FROM lrr_tank_to_archive_map WHERE tankid = ?');
        $delete_sth->execute($tank_id);
        $delete_sth->finish;

        # Insert new archive mappings with positions
        my $insert_sth = $dbh->prepare(
            'INSERT INTO lrr_tank_to_archive_map (tankid, arcid, position, update_date) VALUES (?, ?, ?, CURRENT_DATE)'
        );

        for ( my $i = 0; $i < scalar(@tank_archives); $i++ ) {
            # Position is 1-indexed to match Redis implementation (scores start at 1)
            $insert_sth->execute($tank_id, $tank_archives[$i], $i + 1);
        }
        $insert_sth->finish;

        $logger->debug("Updated archive list for tankoubon $tank_id with " . scalar(@tank_archives) . " archives");
    };

    my $update_error = $@;
    if ($update_error) {
        $err = "Failed to update archive list for tankoubon $tank_id: $update_error";
        $logger->error($err);
        eval { $dbh->rollback };
        $dbh->disconnect();
        return ( 0, $err );
    }

    $dbh->commit;
    $dbh->disconnect();

    # Postgres doesn't need cache invalidation
    return ( 1, $err );
}

# replaces: LANraragi::Model::Tankoubon::update_tankoubon
# update_tankoubon(tankoubonid, data)
#   Updates metadata and archive list.
#   Returns 1 on success, 0 on failure alongside an error message.
sub update_tankoubon {
    my ( $tank_id, $data ) = @_;

    my ( $result, $err ) = update_metadata( $tank_id, $data );
    if ($result) {
        ( $result, $err ) = update_archive_list( $tank_id, $data );
    }

    return ( $result, $err );
}

# replaces: LANraragi::Model::Tankoubon::get_tankoubons_containing_archive
# get_tankoubons_containing_archive(arcid)
#   Gets a list of Tankoubons where archive ID is contained.
#   Returns an array of tank IDs.
sub get_tankoubons_containing_archive {
    my ($arcid) = @_;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();

    # Check if archive exists
    my $arc_check_sth = $dbh->prepare('SELECT arcid FROM lrr_archive WHERE arcid = ?');
    $arc_check_sth->execute($arcid);
    my $arc_exists = $arc_check_sth->fetchrow_hashref;
    $arc_check_sth->finish;

    unless ($arc_exists) {
        my $err = "$arcid does not exist in the database.";
        $logger->error($err);
        $dbh->disconnect();
        return ();
    }

    # Query for all tankoubons containing this archive
    my $tank_sql = <<'SQL';
        SELECT tankid
        FROM lrr_tank_to_archive_map
        WHERE arcid = ?
        ORDER BY tankid
SQL

    my $tank_sth = $dbh->prepare($tank_sql);
    $tank_sth->execute($arcid);

    my @tankoubons;
    while (my $tank_row = $tank_sth->fetchrow_hashref) {
        push @tankoubons, $tank_row->{tankid};
    }
    $tank_sth->finish;

    $dbh->disconnect();
    return @tankoubons;
}

# replaces LANraragi::Model::Tankoubon::delete_tankoubon
# delete_tankoubon(tankoubonid)
#   Deletes the Tankoubon with the given ID.
#   Returns 0 if the given ID isn't a Tankoubon ID, 1 otherwise
sub delete_tankoubon {
    my ($tank_id) = @_;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();

    if ( length($tank_id) != 15 ) {
        # Probably not a Tankoubon ID
        $logger->error("$tank_id is not a Tankoubon ID, doing nothing.");
        $dbh->disconnect();
        return 0;
    }

    # Check if tank exists
    my $tank_check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
    $tank_check_sth->execute($tank_id);
    my $tank_exists = $tank_check_sth->fetchrow_hashref;
    $tank_check_sth->finish;

    unless ($tank_exists) {
        $logger->warn("$tank_id doesn't exist in the database!");
        $dbh->disconnect();
        return 1;
    }

    # Begin transaction for multi-step delete
    $dbh->begin_work;

    eval {
        # First delete from lrr_tank_to_archive_map (no CASCADE in schema)
        my $delete_map_sth = $dbh->prepare('DELETE FROM lrr_tank_to_archive_map WHERE tankid = ?');
        $delete_map_sth->execute($tank_id);
        $delete_map_sth->finish;

        # Then delete from lrr_tank
        my $delete_tank_sth = $dbh->prepare('DELETE FROM lrr_tank WHERE tankid = ?');
        $delete_tank_sth->execute($tank_id);
        $delete_tank_sth->finish;

        $logger->debug("Deleted tankoubon $tank_id");
    };

    if ( my $error = $@ ) {
        $logger->error("Failed to delete tankoubon $tank_id: $error");
        eval { $dbh->rollback };
        $dbh->disconnect();
        return 0;
    }

    $dbh->commit;
    $dbh->disconnect();

    return 1;
}

# replaces LANraragi::Model::Tankoubon::add_to_tankoubon
# add_to_tankoubon(tankoubonid, arcid)
#   Adds the given archive ID to the given Tankoubon.
#   Returns 1 on success, 0 on failure alongside an error message.
sub add_to_tankoubon {
    my ( $tank_id, $arc_id ) = @_;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();
    my $err = "";

    # Check if tank exists
    my $tank_check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
    $tank_check_sth->execute($tank_id);
    my $tank_exists = $tank_check_sth->fetchrow_hashref;
    $tank_check_sth->finish;

    unless ($tank_exists) {
        $err = "$tank_id doesn't exist in the database!";
        $logger->warn($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    # Check if archive exists
    my $arc_check_sth = $dbh->prepare('SELECT arcid FROM lrr_archive WHERE arcid = ?');
    $arc_check_sth->execute($arc_id);
    my $arc_exists = $arc_check_sth->fetchrow_hashref;
    $arc_check_sth->finish;

    unless ($arc_exists) {
        $err = "$arc_id does not exist in the database.";
        $logger->error($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    # Check if archive is already in the tankoubon
    my $check_mapping_sth = $dbh->prepare(
        'SELECT tankid FROM lrr_tank_to_archive_map WHERE tankid = ? AND arcid = ?'
    );
    $check_mapping_sth->execute($tank_id, $arc_id);
    my $already_present = $check_mapping_sth->fetchrow_hashref;
    $check_mapping_sth->finish;

    if ($already_present) {
        $err = "$arc_id already present in category $tank_id, doing nothing.";
        $logger->warn($err);
        $dbh->disconnect();
        return ( 1, $err );
    }

    # Get the next position (current max position + 1)
    # This matches Redis's zcard behavior which returns the number of elements
    my $position_sth = $dbh->prepare(
        'SELECT COALESCE(MAX(position), 0) + 1 as next_position FROM lrr_tank_to_archive_map WHERE tankid = ?'
    );
    $position_sth->execute($tank_id);
    my $position_row = $position_sth->fetchrow_hashref;
    my $next_position = $position_row->{next_position};
    $position_sth->finish;

    # Insert the archive into the tankoubon
    eval {
        my $insert_sth = $dbh->prepare(
            'INSERT INTO lrr_tank_to_archive_map (tankid, arcid, position, update_date) VALUES (?, ?, ?, CURRENT_DATE)'
        );
        $insert_sth->execute($tank_id, $arc_id, $next_position);
        $insert_sth->finish;

        $logger->debug("Added archive $arc_id to tankoubon $tank_id at position $next_position");
    };

    if ( my $error = $@ ) {
        $err = "Failed to add archive to tankoubon: $error";
        $logger->error($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    $dbh->disconnect();
    return ( 1, $err );
}

# replaces LANraragi::Model::Tankoubon::remove_from_tankoubon
# remove_from_tankoubon(tankoubonid, arcid)
#   Removes the given archive ID from the given Tankoubon.
#   Returns 1 on success, 0 on failure alongside an error message.
sub remove_from_tankoubon {
    my ( $tank_id, $arcid ) = @_;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_dbh();
    my $err = "";

    # Check if tank exists
    my $tank_check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
    $tank_check_sth->execute($tank_id);
    my $tank_exists = $tank_check_sth->fetchrow_hashref;
    $tank_check_sth->finish;

    unless ($tank_exists) {
        $err = "$tank_id doesn't exist in the database!";
        $logger->warn($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    # Check if archive exists
    my $arc_check_sth = $dbh->prepare('SELECT arcid FROM lrr_archive WHERE arcid = ?');
    $arc_check_sth->execute($arcid);
    my $arc_exists = $arc_check_sth->fetchrow_hashref;
    $arc_check_sth->finish;

    unless ($arc_exists) {
        $err = "$arcid does not exist in the database.";
        $logger->error($err);
        $dbh->disconnect();
        return ( 0, $err );
    }

    # Check if archive is in the tankoubon and get its position
    my $position_check_sth = $dbh->prepare(
        'SELECT position FROM lrr_tank_to_archive_map WHERE tankid = ? AND arcid = ?'
    );
    $position_check_sth->execute($tank_id, $arcid);
    my $position_row = $position_check_sth->fetchrow_hashref;
    $position_check_sth->finish;

    unless ($position_row) {
        $err = "$arcid not in tankoubon $tank_id, doing nothing.";
        $logger->warn($err);
        $dbh->disconnect();
        return ( 1, $err );
    }

    my $removed_position = $position_row->{position};

    # Begin transaction to remove archive and update positions atomically
    $dbh->begin_work;

    eval {
        # Remove the archive from the tankoubon
        my $delete_sth = $dbh->prepare(
            'DELETE FROM lrr_tank_to_archive_map WHERE tankid = ? AND arcid = ?'
        );
        $delete_sth->execute($tank_id, $arcid);
        $delete_sth->finish;

        # Update positions of all archives that came after the removed one
        # This matches Redis behavior where scores are decremented by 1 for all elements after removal
        my $update_sth = $dbh->prepare(
            'UPDATE lrr_tank_to_archive_map SET position = position - 1 WHERE tankid = ? AND position > ?'
        );
        $update_sth->execute($tank_id, $removed_position);
        $update_sth->finish;

        $logger->debug("Removed archive $arcid from tankoubon $tank_id and updated positions");
    };

    if ( my $error = $@ ) {
        $err = "Failed to remove archive from tankoubon: $error";
        $logger->error($err);
        eval { $dbh->rollback };
        $dbh->disconnect();
        return ( 0, $err );
    }

    $dbh->commit;
    $dbh->disconnect();

    return ( 1, $err );
}

1;
