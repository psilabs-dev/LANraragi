package LANraragi::Model::Extensions::Sqlite;

use strict;
use warnings;
use utf8;

# Metadata database interaction layer.
# May later be refactored to SqliteArchive, SqliteCategory, etc.
# Manages the Sqlite CRUD operations.
# TODO: Copy from Postgresql

sub get_all_untagged_archive_ids {
    my $dbh = shift;
}

sub get_all_archives {
    my $dbh = shift;
}

sub get_archive_metadata_by_id {
    my $dbh = shift;
}

sub update_archive_metadata {
    my $dbh = shift;
}

# Also performs metadata removal
sub delete_archive_metadata_by_id {
    my $dbh = shift;
}

# This will include all archives of a category if available.
sub get_category_metadata_by_id {
    my $dbh = shift;
}

sub update_category_metadata {
    my $dbh = shift;
}

sub delete_category_metadata_by_id {
    my $dbh = shift;
}

sub add_archive_to_category {
    my $dbh = shift;
}

sub remove_archive_from_category {
    my $dbh = shift;
}

sub get_categories_by_arcid {
    my $dbh = shift;
}

# This will include all archives of a tank if available
# Order probably will matter here.
sub get_tank_by_id {
    my $dbh = shift;
}

sub get_tank_metadata_by_id {
    my $dbh = shift;
}

# Probably also involves update archives and order.
sub update_tank {
    my $dbh = shift;
}

sub add_archive_to_tank {
    my $dbh = shift;
}

sub remove_archive_from_tank {
    my $dbh = shift;
}

sub get_tanks_by_arcid {
    my $dbh = shift;
}

1;