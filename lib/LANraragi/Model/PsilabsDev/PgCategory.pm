package LANraragi::Model::PsilabsDev::PgCategory;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Logging qw(get_logger);

# replaces: LANraragi::Model::Category::get_static_category_list
# get_static_category_list()
#   Returns a list of all the static category objects.
sub get_static_category_list {
    my $logger = get_logger("PgCategory", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Query for static categories (where search is NULL or empty string)
    my $cat_sql = <<'SQL';
        SELECT catid, name, pinned, COALESCE(search, '') as search
        FROM lrr_category
        WHERE search IS NULL OR search = ''
        ORDER BY catid
SQL

    my $cat_sth = $dbh->prepare($cat_sql);
    $cat_sth->execute();

    my @result;

    while (my $cat_row = $cat_sth->fetchrow_hashref) {
        my $catid = $cat_row->{catid};

        # Fetch archives for this category
        my $arc_sql = <<'SQL';
            SELECT arcid
            FROM lrr_category_to_archive_map
            WHERE catid = ?
            ORDER BY arcid
SQL

        my $arc_sth = $dbh->prepare($arc_sql);
        $arc_sth->execute($catid);

        my @archives;
        while (my $arc_row = $arc_sth->fetchrow_hashref) {
            push @archives, $arc_row->{arcid};
        }

        # Build category hash matching Redis implementation format
        my %category = (
            id       => $catid,
            name     => $cat_row->{name},
            search   => $cat_row->{search},
            pinned   => $cat_row->{pinned} ? 1 : 0,  # Convert boolean to 1/0
            archives => \@archives
        );

        push @result, \%category;
    }

    $dbh->disconnect();

    $logger->debug("Found " . scalar(@result) . " static categories");

    return @result;
}

# replaces: LANraragi::Model::Category::get_categories_containing_archive
# get_categories_containing_archive(id)
#   Returns a list of all the categories that contain the given archive.
sub get_categories_containing_archive {
    my $archive_id = shift;

    my $logger = get_logger("PgCategory", "lanraragi");
    $logger->debug("Finding categories containing $archive_id");

    my $dbh = get_postgresql_dbh();

    # Query for static categories containing the archive
    my $sql = <<'SQL';
        SELECT c.catid, c.name, c.pinned, COALESCE(c.search, '') as search
        FROM lrr_category c
        INNER JOIN lrr_category_to_archive_map m ON c.catid = m.catid
        WHERE m.arcid = ?
        AND (c.search IS NULL OR c.search = '')
        ORDER BY c.catid
SQL

    my $cat_sth = $dbh->prepare($sql);
    $cat_sth->execute($archive_id);

    my @result;

    while (my $cat_row = $cat_sth->fetchrow_hashref) {
        my $catid = $cat_row->{catid};

        $logger->debug("$archive_id is in '" . $cat_row->{name} . "'");

        # Fetch all archives for this category to match Redis format
        my $arc_sql = <<'SQL';
            SELECT arcid
            FROM lrr_category_to_archive_map
            WHERE catid = ?
            ORDER BY arcid
SQL

        my $arc_sth = $dbh->prepare($arc_sql);
        $arc_sth->execute($catid);

        my @archives;
        while (my $arc_row = $arc_sth->fetchrow_hashref) {
            push @archives, $arc_row->{arcid};
        }

        # Build category hash matching Redis implementation format
        my %category = (
            id       => $catid,
            name     => $cat_row->{name},
            search   => $cat_row->{search},
            pinned   => $cat_row->{pinned} ? 1 : 0,  # Convert boolean to 1/0
            archives => \@archives
        );

        push @result, \%category;
    }

    $dbh->disconnect();

    return @result;
}

# replaces: LANraragi::Model::Category::add_to_category
# add_to_category(categoryid, arcid)
#   Adds the given archive ID to the given category.
#   Only valid if the category is Static.
#   Returns 1 on success, 0 on failure alongside an error message.
sub add_to_category {
    my ( $cat_id, $arc_id ) = @_;
    my $logger = get_logger("PgCategory", "lanraragi");
    my $dbh = get_postgresql_dbh();
    my $err = "";

    # Check if category exists
    my $cat_check_sql = 'SELECT catid, search FROM lrr_category WHERE catid = ?';
    my $cat_sth = $dbh->prepare($cat_check_sql);
    $cat_sth->execute($cat_id);
    my $cat_row = $cat_sth->fetchrow_hashref;

    if (!$cat_row) {
        $err = "$cat_id doesn't exist in the database!";
        $logger->warn($err);
        $dbh->disconnect();
        return (0, $err);
    }

    # Check if category is static (search field is NULL or empty)
    my $search = $cat_row->{search} // '';
    unless ($search eq '') {
        $err = "$cat_id is a favorite search/dynamic category, can't add archives to it.";
        $logger->error($err);
        $dbh->disconnect();
        return (0, $err);
    }

    # Check if archive exists
    my $arc_check_sql = 'SELECT arcid FROM lrr_archive WHERE arcid = ?';
    my $arc_sth = $dbh->prepare($arc_check_sql);
    $arc_sth->execute($arc_id);
    my $arc_row = $arc_sth->fetchrow_hashref;

    if (!$arc_row) {
        $err = "$arc_id does not exist in the database.";
        $logger->error($err);
        $dbh->disconnect();
        return (0, $err);
    }

    # Check if archive is already in the category
    my $check_sql = 'SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ? AND arcid = ?';
    my $check_sth = $dbh->prepare($check_sql);
    $check_sth->execute($cat_id, $arc_id);
    my $exists = $check_sth->fetchrow_hashref;

    if ($exists) {
        $err = "$arc_id already present in category $cat_id, doing nothing.";
        $logger->warn($err);
        $dbh->disconnect();
        return (1, $err);
    }

    # Add archive to category
    my $insert_sql = <<'SQL';
        INSERT INTO lrr_category_to_archive_map (catid, arcid, update_date)
        VALUES (?, ?, CURRENT_DATE)
SQL

    my $insert_sth = $dbh->prepare($insert_sql);
    eval {
        $insert_sth->execute($cat_id, $arc_id);
    };

    if ($@) {
        $err = "Failed to add $arc_id to category $cat_id: $@";
        $logger->error($err);
        $dbh->disconnect();
        return (0, $err);
    }

    $insert_sth->finish;
    $dbh->disconnect();

    $logger->debug("Added $arc_id to category $cat_id");

    # Postgres doesn't need cache invalidation
    return (1, $err);
}

1;
