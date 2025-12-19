package LANraragi::Model::PsilabsDev::PgStats;

use strict;
use warnings;
use utf8;

use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Logging qw(get_logger);

# replaces: LANraragi::Model::Stats::get_archive_count
# get_archive_count()
#   Returns the total number of archives in the database.
#   In Redis, this counts from LRR_TANKGROUPED which contains:
#     - Tank IDs (for non-empty tanks)
#     - Archive IDs that are NOT in any tank
#   In Postgres, we replicate this by counting:
#     - Non-empty tanks (tanks with at least one archive)
#     - All archives that are not in any tank
sub get_archive_count {
    my $logger = get_logger("PgStats", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Count non-empty tanks + archives not in any tank (matching Redis LRR_TANKGROUPED semantics)
    my $sql = <<'SQL';
        SELECT
            (SELECT COUNT(DISTINCT tankid) FROM lrr_tank_to_archive_map) +
            (SELECT COUNT(*) FROM lrr_archive a
             WHERE NOT EXISTS (
                 SELECT 1 FROM lrr_tank_to_archive_map m
                 WHERE m.arcid = a.arcid
             )
            ) as count
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $row = $sth->fetchrow_hashref;
    my $count = $row->{count} || 0;

    $dbh->disconnect();

    $logger->debug("Archive count: $count");

    return $count + 0;  # Return as integer
}

# replaces: LANraragi::Model::Stats::get_page_stat
# get_page_stat()
#   Returns the total number of pages read across all archives.
#   In the Postgres implementation, this sums the progress field from lrr_archive table.
sub get_page_stat {
    my $logger = get_logger("PgStats", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Sum all progress values (pages read)
    my $sql = <<'SQL';
        SELECT COALESCE(SUM(progress), 0) as total_pages
        FROM lrr_archive
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $row = $sth->fetchrow_hashref;
    my $total = $row->{total_pages} || 0;

    $dbh->disconnect();

    $logger->debug("Total pages read: $total");

    return $total + 0;  # Return as integer
}

# replaces: LANraragi::Model::Stats::is_url_recorded
# is_url_recorded($url)
#   Checks if a URL has already been recorded in the database.
#   In Redis, this checks the LRR_URLMAP hash.
#   In Postgres, this queries for archives with a source: tag matching the URL.
#   Returns the archive ID if found, 0 otherwise.
sub is_url_recorded {
    my $url = shift;

    my $logger = get_logger("PgStats", "lanraragi");
    my $dbh = get_postgresql_dbh();

    $logger->debug("Checking if url $url is in the database.");

    # Trim last slash from url if it's present (matching Redis implementation)
    use LANraragi::Utils::String qw(trim_url);
    $url = trim_url($url);

    # Query for archives with a source: tag matching this URL
    my $sql = <<'SQL';
        SELECT a.arcid
        FROM lrr_archive a
        INNER JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
        INNER JOIN lrr_tag t ON atm.tagid = t.tagid
        WHERE t.namespace = 'source' AND t.value = ?
        LIMIT 1
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute($url);

    my $id = 0;
    if (my $row = $sth->fetchrow_hashref) {
        $id = $row->{arcid};
        $logger->debug("Found! id $id.");
    }

    $sth->finish;
    $dbh->disconnect();

    return $id;
}

1;
