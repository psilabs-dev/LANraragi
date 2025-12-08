package LANraragi::Model::PsilabsDev::PgCategory;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Model::Config;

# replaces: LANraragi::Model::Category::get_category_list
# get_category_list()
#   Returns a list of all the category objects.
sub get_category_list {
    my $logger = get_logger("PgCategory", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Query for all categories
    my $cat_sql = <<'SQL';
        SELECT catid, name, pinned, COALESCE(search, '') as search
        FROM lrr_category
        ORDER BY catid
SQL

    my $cat_sth = $dbh->prepare($cat_sql);
    $cat_sth->execute();

    # Prepare archive fetching statement once before loop
    my $arc_sql = <<'SQL';
        SELECT arcid
        FROM lrr_category_to_archive_map
        WHERE catid = ?
        ORDER BY arcid
SQL
    my $arc_sth = $dbh->prepare($arc_sql);

    my @result;

    while (my $cat_row = $cat_sth->fetchrow_hashref) {
        my $catid = $cat_row->{catid};
        my $search = $cat_row->{search};

        my @archives;

        # Only fetch archives for static categories (search is empty)
        if ($search eq '') {
            $arc_sth->execute($catid);

            while (my $arc_row = $arc_sth->fetchrow_hashref) {
                push @archives, $arc_row->{arcid};
            }
            # Don't finish here - allows statement handle reuse
        }

        # Build category hash matching Redis implementation format
        my %category = (
            id       => $catid,
            name     => $cat_row->{name},
            search   => $search,
            pinned   => $cat_row->{pinned} ? 1 : 0,  # Convert boolean to 1/0
            archives => \@archives
        );

        push @result, \%category;
    }
    $cat_sth->finish;
    $arc_sth->finish;

    $dbh->disconnect();

    $logger->debug("Found " . scalar(@result) . " categories");

    return @result;
}

# replaces: LANraragi::Model::Category::get_category
# get_category(categoryid)
#   Returns the category with the given ID.
#   Returns an empty hash if the category doesn't exist.
sub get_category {
    my $cat_id = $_[0];
    my $logger = get_logger("PgCategory", "lanraragi");
    my $dbh = get_postgresql_dbh();

    if ( $cat_id eq "" ) {
        $logger->debug("No category ID provided.");
        $dbh->disconnect();
        return ();
    }

    # Check if category exists and fetch its data
    my $cat_sql = 'SELECT catid, name, pinned, COALESCE(search, \'\') as search FROM lrr_category WHERE catid = ?';
    my $cat_sth = $dbh->prepare($cat_sql);
    $cat_sth->execute($cat_id);
    my $cat_row = $cat_sth->fetchrow_hashref;
    $cat_sth->finish;

    unless ($cat_row) {
        $logger->warn("$cat_id doesn't exist in the database!");
        $dbh->disconnect();
        return ();
    }

    my %category = (
        id     => $cat_id,
        name   => $cat_row->{name},
        search => $cat_row->{search},
        pinned => $cat_row->{pinned} ? 1 : 0,  # Convert boolean to 1/0
    );

    # For static categories, fetch the archives list
    # For dynamic categories, return an empty array
    if ( $category{search} eq "" ) {
        my $arc_sql = <<'SQL';
            SELECT arcid
            FROM lrr_category_to_archive_map
            WHERE catid = ?
            ORDER BY arcid
SQL

        my $arc_sth = $dbh->prepare($arc_sql);
        $arc_sth->execute($cat_id);

        my @archives;
        while (my $arc_row = $arc_sth->fetchrow_hashref) {
            push @archives, $arc_row->{arcid};
        }
        $arc_sth->finish;

        $category{archives} = \@archives;
    } else {
        # Dynamic category - return empty archives array
        $category{archives} = [];
    }

    $dbh->disconnect();

    return %category;
}

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

    # Prepare archive fetching statement once before loop
    my $arc_sql = <<'SQL';
        SELECT arcid
        FROM lrr_category_to_archive_map
        WHERE catid = ?
        ORDER BY arcid
SQL
    my $arc_sth = $dbh->prepare($arc_sql);

    my @result;

    while (my $cat_row = $cat_sth->fetchrow_hashref) {
        my $catid = $cat_row->{catid};

        # Fetch archives for this category
        $arc_sth->execute($catid);

        my @archives;
        while (my $arc_row = $arc_sth->fetchrow_hashref) {
            push @archives, $arc_row->{arcid};
        }
        # Don't finish here - allows statement handle reuse

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
    $cat_sth->finish;
    $arc_sth->finish;

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

    # Prepare archive fetching statement once before loop
    my $arc_sql = <<'SQL';
        SELECT arcid
        FROM lrr_category_to_archive_map
        WHERE catid = ?
        ORDER BY arcid
SQL
    my $arc_sth = $dbh->prepare($arc_sql);

    my @result;

    while (my $cat_row = $cat_sth->fetchrow_hashref) {
        my $catid = $cat_row->{catid};

        $logger->debug("$archive_id is in '" . $cat_row->{name} . "'");

        # Fetch all archives for this category to match Redis format
        $arc_sth->execute($catid);

        my @archives;
        while (my $arc_row = $arc_sth->fetchrow_hashref) {
            push @archives, $arc_row->{arcid};
        }
        # Don't finish here - allows statement handle reuse

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
    $cat_sth->finish;
    $arc_sth->finish;

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
    $cat_sth->finish;

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
    $arc_sth->finish;

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
    $check_sth->finish;

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

    my $insert_error = $@;
    if ($insert_error) {
        $err = "Failed to add $arc_id to category $cat_id: $insert_error";
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

# replaces: LANraragi::Model::Category::create_category
# create_category(name, favtag, pinned, existing_id)
#   Create a Category.
#   If the "favtag" argument is supplied, the category will be Dynamic.
#   Otherwise, it'll be Static.
#   If an existing category ID is supplied, said category will be updated with the given parameters.
#   Returns the ID of the created/updated Category.
sub create_category {
    my ( $name, $favtag, $pinned, $cat_id ) = @_;
    my $logger = get_logger("PgCategory", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Set all fields of the category object
    unless ( length($cat_id) ) {
        $cat_id = "SET_" . time();

        my $isnewkey = 0;
        # Prepare statement ONCE before the loop
        my $check_sth = $dbh->prepare('SELECT catid FROM lrr_category WHERE catid = ?');

        until ($isnewkey) {
            # Check if the category ID exists, move timestamp further if it does
            $check_sth->execute($cat_id);
            my $exists = $check_sth->fetchrow_hashref;

            if ($exists) {
                $cat_id = "SET_" . ( time() + 1 );
            } else {
                $isnewkey = 1;
            }
        }

        $check_sth->finish;  # Finish AFTER loop
    }

    # Check if category exists
    my $exists_sth = $dbh->prepare('SELECT catid FROM lrr_category WHERE catid = ?');
    $exists_sth->execute($cat_id);
    my $existing = $exists_sth->fetchrow_hashref;
    $exists_sth->finish;

    # Convert pinned to boolean
    my $pinned_bool = $pinned ? 1 : 0;

    if ($existing) {
        # Update existing category
        my $update_sth = $dbh->prepare(
            'UPDATE lrr_category SET name = ?, search = ?, pinned = ? WHERE catid = ?'
        );
        $update_sth->execute($name, $favtag, $pinned_bool, $cat_id);
        $update_sth->finish;
        $logger->debug("Updated category $cat_id");
    } else {
        # Insert new category
        my $insert_sth = $dbh->prepare(
            'INSERT INTO lrr_category (catid, name, search, pinned) VALUES (?, ?, ?, ?)'
        );
        $insert_sth->execute($cat_id, $name, $favtag, $pinned_bool);
        $insert_sth->finish;
        $logger->debug("Created new category $cat_id");
    }

    $dbh->disconnect();
    return $cat_id;
}

# replaces: LANraragi::Model::Category::get_bookmark_link
# get_bookmark_link()
#   Gets the ID of the category that is linked to the bookmark button.
#   If no such ID exists, returns an empty string.
sub get_bookmark_link {
    my $redis = LANraragi::Model::Config->get_redis_config();
    my $catid = $redis->hget('LRR_CONFIG', 'bookmark_link') || "";
    $redis->quit();
    return $catid;
}

# replaces: LANraragi::Model::Category::update_bookmark_link
# update_bookmark_link(cat_id)
#   Links the bookmark button to a static category.
#   Returns an HTTP status code, category ID, and response message.
sub update_bookmark_link {
    my $cat_id = shift;
    my $logger = get_logger("PgCategory", "lanraragi");

    unless (defined $cat_id && $cat_id =~ /^SET_\d{10}$/) {
        return (400, $cat_id, "Input category ID is invalid.");
    }

    my $dbh = get_postgresql_dbh();

    # Check if category exists using Postgres
    my $check_sql = 'SELECT catid, search FROM lrr_category WHERE catid = ?';
    my $check_sth = $dbh->prepare($check_sql);
    $check_sth->execute($cat_id);
    my $cat_row = $check_sth->fetchrow_hashref;
    $check_sth->finish;

    unless ($cat_row) {
        $dbh->disconnect();
        return (404, $cat_id, "Category does not exist!");
    }

    # Check if category is static (search field is NULL or empty)
    my $search = $cat_row->{search} // '';
    unless ($search eq '') {
        $dbh->disconnect();
        return (400, $cat_id, "Cannot link bookmark to a dynamic category.");
    }

    $dbh->disconnect();

    # Store bookmark_link in Redis config
    my $redis = LANraragi::Model::Config->get_redis_config();
    $redis->hset('LRR_CONFIG', 'bookmark_link', $cat_id);
    $redis->quit();

    $logger->info("Updated bookmark link to category $cat_id");
    return (200, $cat_id, "success");
}

# replaces: LANraragi::Model::Category::remove_bookmark_link
# remove_bookmark_link()
#   Unlinks the bookmark from its current category and returns the category ID.
sub remove_bookmark_link {
    my $logger = get_logger("PgCategory", "lanraragi");
    my $redis = LANraragi::Model::Config->get_redis_config();
    my $cat_id = $redis->hget('LRR_CONFIG', 'bookmark_link') || "";
    $redis->hdel('LRR_CONFIG', 'bookmark_link');
    $redis->quit();
    $logger->info("Removed bookmark link from category " . ($cat_id || "(none)"));
    return $cat_id;
}

# replaces: LANraragi::Model::Category::remove_from_category
# remove_from_category(categoryid, arcid)
#   Removes the given archive ID from the given category.
#   Only valid if the category is a Static category.
#   Returns 1 on success, 0 on failure alongside an error message.
sub remove_from_category {
    my ( $cat_id, $arc_id ) = @_;
    my $logger = get_logger("PgCategory", "lanraragi");
    my $dbh = get_postgresql_dbh();
    my $err = "";

    # Check if category exists
    my $cat_check_sql = 'SELECT catid, search FROM lrr_category WHERE catid = ?';
    my $cat_sth = $dbh->prepare($cat_check_sql);
    $cat_sth->execute($cat_id);
    my $cat_row = $cat_sth->fetchrow_hashref;
    $cat_sth->finish;

    if (!$cat_row) {
        $err = "$cat_id doesn't exist in the database!";
        $logger->warn($err);
        $dbh->disconnect();
        return (0, $err);
    }

    # Check if category is static (search field is NULL or empty)
    my $search = $cat_row->{search} // '';
    unless ($search eq '') {
        $err = "$cat_id is a favorite search, it doesn't contain archives.";
        $logger->error($err);
        $dbh->disconnect();
        return (0, $err);
    }

    # Remove archive from category
    my $delete_sql = 'DELETE FROM lrr_category_to_archive_map WHERE catid = ? AND arcid = ?';
    my $delete_sth = $dbh->prepare($delete_sql);
    eval {
        $delete_sth->execute($cat_id, $arc_id);
    };

    my $delete_error = $@;
    if ($delete_error) {
        $err = "Failed to remove $arc_id from category $cat_id: $delete_error";
        $logger->error($err);
        $dbh->disconnect();
        return (0, $err);
    }

    $delete_sth->finish;
    $dbh->disconnect();

    $logger->debug("Removed $arc_id from category $cat_id");

    # Postgres doesn't need cache invalidation
    return (1, $err);
}

# replaces: LANraragi::Model::Category::delete_category
# delete_category(id)
#   Deletes the category with the given ID.
#   If bookmark is linked to the category, remove the link.
#   Returns 0 if the given ID isn't a category ID, 1 otherwise
sub delete_category {
    my $cat_id = $_[0];
    my $logger = get_logger("PgCategory", "lanraragi");

    if ( length($cat_id) != 14 ) {
        # Probably not a category ID
        $logger->error("$cat_id is not a category ID, doing nothing.");
        return 0;
    }

    my $dbh = get_postgresql_dbh();

    # Check if category exists
    my $check_sql = 'SELECT catid FROM lrr_category WHERE catid = ?';
    my $check_sth = $dbh->prepare($check_sql);
    $check_sth->execute($cat_id);
    my $exists = $check_sth->fetchrow_hashref;
    $check_sth->finish;

    if ($exists) {
        # Check if bookmark is linked to this category and remove if so
        my $redis = LANraragi::Model::Config->get_redis_config();
        my $bookmark_catid = $redis->hget('LRR_CONFIG', 'bookmark_link') || "";

        if ($bookmark_catid eq $cat_id) {
            $redis->hdel('LRR_CONFIG', 'bookmark_link');
            $logger->info("Removed link from bookmark to category $cat_id.");
        }
        $redis->quit();

        # Delete the category
        # First, delete all archive mappings for this category
        # Then delete the category itself
        $dbh->begin_work();
        eval {
            # Delete archive mappings
            my $delete_map_sql = 'DELETE FROM lrr_category_to_archive_map WHERE catid = ?';
            my $delete_map_sth = $dbh->prepare($delete_map_sql);
            $delete_map_sth->execute($cat_id);
            $delete_map_sth->finish;

            # Delete the category
            my $delete_cat_sql = 'DELETE FROM lrr_category WHERE catid = ?';
            my $delete_cat_sth = $dbh->prepare($delete_cat_sql);
            $delete_cat_sth->execute($cat_id);
            $delete_cat_sth->finish;

            $dbh->commit();
        };

        if ( my $error = $@ ) {
            $dbh->rollback();
            $logger->error("Error deleting category $cat_id: $error");
            $dbh->disconnect();
            return 0;
        }

        $dbh->disconnect();
        $logger->info("Deleted category $cat_id");
        return 1;
    } else {
        $logger->warn("$cat_id doesn't exist in the database!");
        $dbh->disconnect();
        return 1;
    }
}

1;
