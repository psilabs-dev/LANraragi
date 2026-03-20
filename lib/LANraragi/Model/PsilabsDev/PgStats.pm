package LANraragi::Model::PsilabsDev::PgStats;

use strict;
use warnings;
use utf8;

use Mojo::JSON qw(encode_json decode_json);

use LANraragi::Utils::PsilabsDev::Database qw(get_dbh);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Redis    qw(redis_decode);
use LANraragi::Model::Config;

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
    my $dbh = get_dbh();

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

    $sth->finish;
    $dbh->disconnect();

    $logger->debug("Archive count: $count");

    return $count + 0;  # Return as integer
}

# replaces: LANraragi::Model::Stats::get_page_stat
# get_page_stat()
#   Returns the cumulative total number of pages read across all archives.
#   Reads from LRR_TOTALPAGESTAT in Redis Database 2 (configuration database).
#   This counter is incremented each time a user reads a page.
#   Configuration exception: This remains in Redis as it's stored in the config database.
sub get_page_stat {
    my $logger = get_logger("PgStats", "lanraragi");

    my $redis = LANraragi::Model::Config->get_redis_config;
    my $stat  = ($redis->get("LRR_TOTALPAGESTAT") || 0) + 0;
    $redis->quit();

    $logger->debug("Total pages read: $stat");

    return $stat;
}

# replaces: LANraragi::Model::Stats::compute_content_size
# compute_content_size()
#   Computes the total size of all archives in the database.
#   In Redis, this sums the arcsize field from all archive hashes.
#   In Postgres, this sums the arcsize column from lrr_archive table.
#   Returns the size in GB (as a decimal number).
sub compute_content_size {
    my $logger = get_logger("PgStats", "lanraragi");
    my $dbh = get_dbh();

    # Sum all archive sizes
    my $sql = <<'SQL';
        SELECT COALESCE(SUM(arcsize), 0) as total_size
        FROM lrr_archive
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $row = $sth->fetchrow_hashref;
    my $size = $row->{total_size} || 0;

    $sth->finish;
    $dbh->disconnect();

    # Convert to GB (matching Redis implementation)
    my $size_gb = int( $size / 1073741824 * 100 ) / 100;

    $logger->debug("Total content size: $size_gb GB");

    return $size_gb;
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
    my $dbh = get_dbh();

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

# replaces: LANraragi::Model::Stats::build_tag_stats
# build_tag_stats($minscore, $excluded)
#   Builds tag statistics for display in the tag cloud.
#   Results are cached as raw JSON in Redis (search DB) under LRR_TAG_STATS:*
#   keyed by query parameters. Cache is invalidated by invalidate_tag_stats_cache(),
#   called from PgDatabase::invalidate_cache.
#
#   Returns ($json_string, 1) on cache hit — caller renders the raw JSON directly.
#   Returns ($arrayref, 0) on cache miss — caller renders via openapi.
sub build_tag_stats {
    my ( $minscore, $excluded ) = @_;
    my $logger = get_logger("PgStats", "lanraragi");

    $logger->debug("Serving tag statistics with a minimum weight of $minscore");

    # Build a cache key from parameters
    my $excl_key = join( ',', sort map { lc($_) } @$excluded );
    my $cache_key = "LRR_TAG_STATS:${minscore}:${excl_key}";

    # Check Redis cache — return raw JSON string on hit to avoid decode+re-encode
    my $redis = LANraragi::Model::Config->get_redis_search;
    my $cached = $redis->get($cache_key);
    $redis->quit();

    if ($cached) {
        $logger->debug("Tag stats cache hit for $cache_key");
        return ( redis_decode($cached), 1 );
    }

    # Cache miss — compute from Postgres
    my $dbh = get_dbh();

    my @params;

    my $exclude_clause = "";
    if ( @$excluded ) {
        my @placeholders = map { '?' } @$excluded;
        $exclude_clause = "WHERE LOWER(atm.namespace) NOT IN (" . join( ', ', @placeholders ) . ")";
        push @params, map { lc($_) } @$excluded;
    }

    # HAVING ? comes after WHERE ? in bind order
    push @params, $minscore;

    my $sql = <<SQL;
        SELECT LOWER(atm.namespace) as namespace, LOWER(atm.value) as value, COUNT(*) as weight
        FROM lrr_archive_to_tag_map atm
        $exclude_clause
        GROUP BY LOWER(atm.namespace), LOWER(atm.value)
        HAVING COUNT(*) >= ?
        ORDER BY weight DESC
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my @tags;
    while (my $row = $sth->fetchrow_hashref) {
        my $value = $row->{value} || "";
        next if $value eq "";

        push @tags, {
            text      => $value,
            namespace => $row->{namespace} || "",
            weight    => $row->{weight} + 0
        };
    }

    $sth->finish;
    $dbh->disconnect();

    # Store rendered JSON in Redis cache
    my $json = encode_json( \@tags );
    $redis = LANraragi::Model::Config->get_redis_search;
    $redis->set( $cache_key, $json );
    $redis->quit();

    $logger->debug("Returning " . scalar(@tags) . " tags (cached under $cache_key)");

    return ( \@tags, 0 );
}

# invalidate_tag_stats_cache()
#   Deletes all LRR_TAG_STATS:* keys from the Redis search DB.
#   Called by PgDatabase::invalidate_cache on tag writes.
sub invalidate_tag_stats_cache {
    my $redis = LANraragi::Model::Config->get_redis_search;
    my @keys = $redis->keys("LRR_TAG_STATS:*");

    if (@keys) {
        $redis->del(@keys);
        my $logger = get_logger("PgStats", "lanraragi");
        $logger->debug("Invalidated " . scalar(@keys) . " tag stats cache entries");
    }

    $redis->quit();
}

# replaces: LANraragi::Model::Stats::build_stat_hashes
# build_stat_hashes()
#   In Redis, this rebuilds multiple search indexes:
#     - LRR_URL_MAP (URL to archive ID mapping)
#     - LRR_STATS (tag statistics/counts)
#     - LRR_UNTAGGED (set of untagged archives)
#     - LRR_NEW (set of new archives)
#     - LRR_TITLES (lexicographically sorted titles)
#     - LRR_TANKGROUPED (tank IDs and archives not in tanks)
#     - INDEX_<tag> (individual tag search indexes)
#
#   In Postgres, these indexes are maintained automatically:
#     - Tag statistics are computed on-the-fly via SQL queries
#     - URL lookups use JOIN queries on lrr_tag table
#     - Untagged/new filtering uses WHERE clauses
#
#   This function is a no-op for Postgres but must exist for compatibility.
sub build_stat_hashes {
    my $logger = get_logger("PgStats", "lanraragi");

    $logger->info("build_stat_hashes called - no-op for Postgres (indexes maintained automatically)");

    # No manual index building is required for Postgres.
    # This function exists only for compatibility with the Minion task system.

    return;
}

1;
