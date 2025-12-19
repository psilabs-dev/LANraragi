package LANraragi::Utils::PsilabsDev::PgDatabase;

use strict;
use warnings;
use utf8;

use feature qw(signatures);
no warnings 'experimental::signatures';

use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Tags qw(split_tags_to_array join_tags_to_string);
use LANraragi::Utils::String qw(trim trim_CRLF);
use List::MoreUtils qw(uniq);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);

# Functions for interacting with Postgres.
use Exporter 'import';
our @EXPORT_OK = qw(
  set_tags set_tags_with_dbh set_title set_title_with_dbh set_summary set_summary_with_dbh invalidate_cache
);

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
        # The search_tsv includes title and tags, so we need to regenerate it
        my $update_tsv_sth = $dbh->prepare(q{
            UPDATE lrr_archive
            SET search_tsv = to_tsvector('simple',
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

# replaces LANraragi::Utils::Database::invalidate_cache
# In Postgres, there's no separate search cache to invalidate.
# The search_tsv column is kept in sync with updates, so this is a no-op.
sub invalidate_cache ( $rebuild_indexes = 0 ) {
    # No-op for Postgres - search index is always up to date via search_tsv
    # The $rebuild_indexes parameter is ignored as well
    return;
}

1;
