package LANraragi::Model::Extensions::Postgres;

use strict;
use warnings;
use utf8;

# Metadata database interaction layer.
# May later be refactored to PostgresArchive, PostgresCategory, etc.
# Manages the Postgresql CRUD operations.

# Get total number of archives.
sub get_num_archives {
    my $dbh = shift;
    my $response = $dbh->selectrow_array("SELECT COUNT(*) FROM lrr_archive");
    return $response;
}

# TODO: what constitutes an untagged archive?
sub get_all_untagged_archive_ids {
    my $dbh = shift;
}

# TODO
sub get_all_archives {
    my $dbh = shift;
}

# TODO: check if correct.
sub get_archive_metadata_by_id {
    my $dbh   = shift;
    my $arcid = shift;
    
    my $sth = $dbh->prepare(
        "SELECT "
        . "arcid, filename, extension,"
        . "isnew, lastreadtime, pagecount, progress,"
        . "title, tags, summary "
        . "FROM lrr_archive WHERE id=?"
    );
    
    my $result = $sth->execute($arcid);
    
    # Check if execution was successful
    if (!$result) {
        die "Query execution failed: " . $sth->errstr;
    }
    
    # Fetch and return the row
    my $row = $sth->fetchrow_hashref();
    return $row;
}


# TODO
sub update_archive_metadata {
    my $dbh = shift;
}

# TODO
# Also performs metadata removal
sub delete_archive_metadata_by_id {
    my $dbh = shift;
}

# TODO
# This will include all archives of a category if available.
sub get_category_metadata_by_id {
    my $dbh = shift;
}

# TODO
sub update_category_metadata {
    my $dbh = shift;
}

# TODO
sub delete_category_metadata_by_id {
    my $dbh = shift;
}

# TODO
sub add_archive_to_category {
    my $dbh = shift;
}

# TODO
sub remove_archive_from_category {
    my $dbh = shift;
}

# TODO
sub get_categories_by_arcid {
    my $dbh = shift;
}

# This will include all archives of a tank if available
# Order probably will matter here.
sub get_tank_by_id {
    my $dbh = shift;
}

# TODO
sub get_tank_metadata_by_id {
    my $dbh = shift;
}

# TODO
# Probably also involves update archives and order.
sub update_tank {
    my $dbh = shift;
}

# TODO
sub add_archive_to_tank {
    my $dbh = shift;
}

# TODO
sub remove_archive_from_tank {
    my $dbh = shift;
}

# TODO
sub get_tanks_by_arcid {
    my $dbh = shift;
}

1;