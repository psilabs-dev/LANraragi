package LANraragi::Model::PsilabsDev::PgBackup;

use strict;
use warnings;
use utf8;

use Mojo::JSON qw(encode_json decode_json);

use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Model::PsilabsDev::PgTankoubon;
use LANraragi::Utils::PsilabsDev::PgDatabase qw(clean_categories_and_tanks);

# replaces LANraragi::Model::Backup::build_backup_JSON
# build_backup_JSON()
#   Goes through the Postgres database and builds a JSON string containing archive metadata.
sub build_backup_JSON {
    my $dbh = get_postgresql_dbh();
    my $logger = get_logger("Backup/Restore", "lanraragi");

    # Basic structure of the backup object
    my %backup = (
        categories => [],
        tankoubons => [],
        archives   => []
    );

    # Backup categories first
    my $cat_sql = <<'SQL';
        SELECT catid, name, COALESCE(search, '') as search
        FROM lrr_category
        ORDER BY catid
SQL

    my $cat_sth = $dbh->prepare($cat_sql);
    $cat_sth->execute();

    while (my $cat_row = $cat_sth->fetchrow_hashref) {
        my $catid = $cat_row->{catid};

        eval {
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

            # Build category hash matching Redis backup format
            my %category = (
                catid    => $catid,
                name     => $cat_row->{name},
                search   => $cat_row->{search},
                archives => \@archives
            );

            push @{ $backup{categories} }, \%category;
        };

        $logger->trace("Backing up category $catid: $@");
    }

    # Backup tanks
    my ($total, $filtered, @tanks) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon_list(-1);
    foreach my $tank (@tanks) {
        my $tank_id       = $tank->{id};
        my $tank_title    = $tank->{name};
        my @tank_archives = @{ $tank->{archives} };

        my %tank = (
            tankid   => $tank_id,
            name     => $tank_title,
            archives => \@tank_archives
        );

        push @{ $backup{tankoubons} }, \%tank;
    }

    # Backup archives themselves next
    my $arc_sql = <<'SQL';
        SELECT arcid, filename, title, summary, thumbhash
        FROM lrr_archive
        ORDER BY arcid
SQL

    my $arc_sth = $dbh->prepare($arc_sql);
    $arc_sth->execute();

    while (my $arc_row = $arc_sth->fetchrow_hashref) {
        my $id = $arc_row->{arcid};

        eval {
            # Get tags for this archive
            my $tag_sql = <<'SQL';
                SELECT CASE
                    WHEN t.namespace = '' THEN t.value
                    ELSE t.namespace || ':' || t.value
                END as tag
                FROM lrr_archive_to_tag_map m
                JOIN lrr_tag t ON m.tagid = t.tagid
                WHERE m.arcid = ?
                ORDER BY t.tagid
SQL

            my $tag_sth = $dbh->prepare($tag_sql);
            $tag_sth->execute($id);

            my @tags;
            while (my $tag_row = $tag_sth->fetchrow_hashref) {
                push @tags, $tag_row->{tag};
            }

            my $tags_str = join(', ', @tags);

            # Backup all user-generated metadata, alongside the unique ID
            my %arc = (
                arcid     => $id,
                title     => $arc_row->{title}      // '',
                tags      => $tags_str,
                summary   => $arc_row->{summary}    // '',
                thumbhash => $arc_row->{thumbhash}  // '',
                filename  => $arc_row->{filename}
            );

            push @{ $backup{archives} }, \%arc;
        };

        $logger->trace("Backing up archive $id: $@");
    }

    $dbh->disconnect();
    return encode_json \%backup;
}

# replaces LANraragi::Model::Backup::restore_from_JSON
# restore_from_JSON(backupJSON)
#   Restores metadata from a JSON to the Postgres database, for existing IDs.
sub restore_from_JSON {
    my $json_str = shift;
    my $logger = get_logger("Backup/Restore", "lanraragi");
    my $json = decode_json($json_str);

    $logger->info("Received a JSON backup to restore.");

    my $dbh = get_postgresql_dbh();

    # Clean categories and tankoubons before restoring from JSON
    eval {
        LANraragi::Utils::PsilabsDev::PgDatabase::clean_categories_and_tanks();
    };

    my $clean_error = $@;
    if ($clean_error) {
        $logger->error("Failed to clean categories and tankoubons: $clean_error");
        $dbh->disconnect();
        return;
    }

    # Restore categories
    foreach my $category (@{ $json->{categories} }) {
        my $cat_id = $category->{"catid"};
        $logger->info("Restoring Category $cat_id...");

        my $name     = $category->{"name"};
        my $search   = $category->{"search"} // '';
        my @archives = @{ $category->{"archives"} // [] };

        eval {
            $dbh->begin_work();

            # Create category
            my $insert_cat_sql = <<'SQL';
                INSERT INTO lrr_category (catid, name, pinned, search)
                VALUES (?, ?, ?, ?)
                ON CONFLICT (catid) DO UPDATE
                SET name = EXCLUDED.name, search = EXCLUDED.search
SQL

            my $insert_cat_sth = $dbh->prepare($insert_cat_sql);
            $insert_cat_sth->execute($cat_id, $name, 0, $search);

            # Add archives to category
            foreach my $arcid (@archives) {
                # Check if archive exists
                my $check_arc_sql = 'SELECT arcid FROM lrr_archive WHERE arcid = ?';
                my $check_arc_sth = $dbh->prepare($check_arc_sql);
                $check_arc_sth->execute($arcid);
                my $arc_exists = $check_arc_sth->fetchrow_hashref;

                if ($arc_exists) {
                    my $insert_map_sql = <<'SQL';
                        INSERT INTO lrr_category_to_archive_map (catid, arcid, update_date)
                        VALUES (?, ?, CURRENT_DATE)
                        ON CONFLICT DO NOTHING
SQL

                    my $insert_map_sth = $dbh->prepare($insert_map_sql);
                    $insert_map_sth->execute($cat_id, $arcid);
                }
            }

            $dbh->commit();
        };

        my $cat_error = $@;
        if ($cat_error) {
            $logger->error("Failed to restore category $cat_id: $cat_error");
            $dbh->rollback();
        }
    }

    # Restore tankoubons
    foreach my $tank (@{ $json->{tankoubons} // [] }) {
        my $tank_id = $tank->{"tankid"};
        $logger->info("Restoring Tankoubon $tank_id...");

        my $name     = $tank->{"name"};
        my @archives = @{ $tank->{"archives"} // [] };

        eval {
            $dbh->begin_work();

            # Create tankoubon
            my $insert_tank_sql = <<'SQL';
                INSERT INTO lrr_tank (tankid, name, summary, tags)
                VALUES (?, ?, '', '')
                ON CONFLICT (tankid) DO UPDATE
                SET name = EXCLUDED.name
SQL

            my $insert_tank_sth = $dbh->prepare($insert_tank_sql);
            $insert_tank_sth->execute($tank_id, $name);

            # Add archives to tankoubon with position
            my $position = 1;
            foreach my $arcid (@archives) {
                # Check if archive exists
                my $check_arc_sql = 'SELECT arcid FROM lrr_archive WHERE arcid = ?';
                my $check_arc_sth = $dbh->prepare($check_arc_sql);
                $check_arc_sth->execute($arcid);
                my $arc_exists = $check_arc_sth->fetchrow_hashref;

                if ($arc_exists) {
                    my $insert_map_sql = <<'SQL';
                        INSERT INTO lrr_tank_to_archive_map (tankid, arcid, position, update_date)
                        VALUES (?, ?, ?, CURRENT_DATE)
                        ON CONFLICT DO NOTHING
SQL

                    my $insert_map_sth = $dbh->prepare($insert_map_sql);
                    $insert_map_sth->execute($tank_id, $arcid, $position);
                    $position++;
                }
            }

            $dbh->commit();
        };

        my $tank_error = $@;
        if ($tank_error) {
            $logger->error("Failed to restore tankoubon $tank_id: $tank_error");
            $dbh->rollback();
        }
    }

    # Restore archive metadata
    foreach my $archive (@{ $json->{archives} }) {
        my $id = $archive->{"arcid"};

        eval {
            # Check if archive exists
            my $check_sql = 'SELECT arcid FROM lrr_archive WHERE arcid = ?';
            my $check_sth = $dbh->prepare($check_sql);
            $check_sth->execute($id);
            my $exists = $check_sth->fetchrow_hashref;

            if ($exists) {
                $logger->info("Restoring metadata for Archive $id...");

                $dbh->begin_work();

                # Update archive metadata
                my $update_sql = <<'SQL';
                    UPDATE lrr_archive
                    SET title = ?, summary = ?, thumbhash = ?
                    WHERE arcid = ?
SQL

                my $update_sth = $dbh->prepare($update_sql);
                $update_sth->execute(
                    $archive->{"title"} // '',
                    $archive->{"summary"} // '',
                    $archive->{"thumbhash"} // '',
                    $id
                );

                # Parse and insert tags
                my $tags_str = $archive->{"tags"} // '';
                if ($tags_str) {
                    # Delete existing tags for this archive
                    my $delete_tags_sql = 'DELETE FROM lrr_archive_to_tag_map WHERE arcid = ?';
                    my $delete_tags_sth = $dbh->prepare($delete_tags_sql);
                    $delete_tags_sth->execute($id);

                    # Split tags by comma
                    my @tags = split(/,\s*/, $tags_str);
                    foreach my $tag (@tags) {
                        next unless $tag;

                        my ($namespace, $value);
                        if ($tag =~ /^([^:]+):(.+)$/) {
                            $namespace = $1;
                            $value = $2;
                        } else {
                            $namespace = '';
                            $value = $tag;
                        }

                        # Insert or get tag
                        my $insert_tag_sql = <<'SQL';
                            INSERT INTO lrr_tag (namespace, value)
                            VALUES (?, ?)
                            ON CONFLICT (namespace, value) DO UPDATE
                            SET namespace = EXCLUDED.namespace
                            RETURNING tagid
SQL

                        my $insert_tag_sth = $dbh->prepare($insert_tag_sql);
                        $insert_tag_sth->execute($namespace, $value);
                        my $tag_row = $insert_tag_sth->fetchrow_hashref;
                        my $tagid = $tag_row->{tagid};

                        # Link tag to archive
                        my $insert_map_sql = <<'SQL';
                            INSERT INTO lrr_archive_to_tag_map (arcid, tagid, update_date)
                            VALUES (?, ?, CURRENT_DATE)
                            ON CONFLICT DO NOTHING
SQL

                        my $insert_map_sth = $dbh->prepare($insert_map_sql);
                        $insert_map_sth->execute($id, $tagid);
                    }
                }

                # Update the search_tsv column for full-text search
                # This is critical for making restored archives searchable
                my $update_tsv_sql = <<'SQL';
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
SQL

                my $update_tsv_sth = $dbh->prepare($update_tsv_sql);
                $update_tsv_sth->execute($id);

                $dbh->commit();
            }
        };

        my $arc_error = $@;
        if ($arc_error) {
            $logger->error("Failed to restore archive $id: $arc_error");
            $dbh->rollback() if $dbh->{AutoCommit} == 0;
        }
    }

    $dbh->disconnect();
    $logger->info("Backup restore completed.");
}

1;
