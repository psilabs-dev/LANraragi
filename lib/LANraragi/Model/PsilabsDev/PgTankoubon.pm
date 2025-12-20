package LANraragi::Model::PsilabsDev::PgTankoubon;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Model::Config;

# replaces LANraragi::Model::Tankoubon::get_tankoubon_list
# get_tankoubon_list(page)
#   Returns a list of all the Tankoubon objects.
sub get_tankoubon_list {
    my $page = shift // 0;

    my $logger = get_logger("PgTankoubon", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Get all tankoubons
    my $tank_sql = <<'SQL';
        SELECT tankid, name, summary, tags
        FROM lrr_tank
        ORDER BY tankid
SQL

    my $tank_sth = $dbh->prepare($tank_sql);
    $tank_sth->execute();

    my @result;

    while (my $tank_row = $tank_sth->fetchrow_hashref) {
        my $tankid = $tank_row->{tankid};

        # Fetch archives for this tankoubon
        my $arc_sql = <<'SQL';
            SELECT arcid
            FROM lrr_tank_to_archive_map
            WHERE tankid = ?
            ORDER BY position
SQL

        my $arc_sth = $dbh->prepare($arc_sql);
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
            return ($total, 0);
        }

        my @page_results = @result[$start .. $end];
        return ($total, scalar(@page_results), @page_results);
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
    my $dbh = get_postgresql_dbh();

    # Set all fields of the tank object
    unless ( length($tank_id) ) {
        $tank_id = "TANK_" . time();

        my $isnewkey = 0;
        until ($isnewkey) {
            # Check if the tank ID exists, move timestamp further if it does
            my $check_sth = $dbh->prepare('SELECT tankid FROM lrr_tank WHERE tankid = ?');
            $check_sth->execute($tank_id);
            my $exists = $check_sth->fetchrow_hashref;
            $check_sth->finish;

            if ($exists) {
                $tank_id = "TANK_" . ( time() + 1 );
            } else {
                $isnewkey = 1;
            }
        }
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
    my $dbh = get_postgresql_dbh();
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
    foreach my $arc_id (@tank_archives) {
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
    }

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

1;
