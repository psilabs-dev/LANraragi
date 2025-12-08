package LANraragi::Model::PsilabsDev::PgSearch;

use feature qw(signatures);
no warnings 'experimental::signatures';

use strict;
use warnings;
use utf8;

use List::Util qw(min);
use Time::HiRes qw(time);
use LANraragi::Utils::Generic qw(intersect_arrays);
use LANraragi::Utils::String qw(trim);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Model::Config;
use LANraragi::Model::PsilabsDev::PgCategory;

# replaces LANraragi::Model::Search::do_search
# Performs a search on the Postgres database.
# Returns ($total, $filtered, @ids)
sub do_search ( $filter, $category_id, $start, $sortkey, $sortorder, $newonly, $untaggedonly, $grouptanks ) {

    my $logger = get_logger( "PgSearch Engine", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    my ( $total, $filtered, @ids );
    my $start_time = time();

    eval {
        # Get total count of archives
        my $count_start = time();
        if ($grouptanks) {
            # When grouping tanks: count standalone archives + tank count
            # Standalone archives = archives not in any tank
            my $archive_count_sth = $dbh->prepare(
                'SELECT COUNT(*) FROM lrr_archive WHERE NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = lrr_archive.arcid)'
            );
            $archive_count_sth->execute();
            my ($archive_count) = $archive_count_sth->fetchrow_array;
            $archive_count_sth->finish;

            my $tank_count_sth = $dbh->prepare('SELECT COUNT(*) FROM lrr_tank');
            $tank_count_sth->execute();
            my ($tank_count) = $tank_count_sth->fetchrow_array;
            $tank_count_sth->finish;

            $total = ($archive_count || 0) + ($tank_count || 0);
        } else {
            # When not grouping tanks: count all archives (excluding tanks themselves)
            my $count_sth = $dbh->prepare('SELECT COUNT(*) FROM lrr_archive');
            $count_sth->execute();
            my ($count) = $count_sth->fetchrow_array;
            $count_sth->finish;
            $total = $count || 0;
        }
        my $count_time = (time() - $count_start) * 1000;
        $logger->debug(sprintf("[PERF] Total count: %.2fms (grouptanks: %s)", $count_time, $grouptanks ? 'true' : 'false'));

        # Determine pagination parameters
        my $keysperpage = LANraragi::Model::Config->get_pagesize;
        my $use_pagination = ( $start != -1 );

        # Perform the search with SQL-level pagination
        my $search_start = time();
        ( $filtered, @ids ) = search_postgres_with_dbh(
            $dbh, $category_id, $filter, $sortkey, $sortorder,
            $newonly, $untaggedonly, $grouptanks,
            $use_pagination ? $start : undef,
            $use_pagination ? $keysperpage : undef
        );
        my $search_time = (time() - $search_start) * 1000;
        $logger->debug(sprintf("[PERF] search_postgres total: %.2fms", $search_time));
    };

    if ( my $error = $@ ) {
        $logger->error("Search error: $error");
        $dbh->disconnect();
        return ( -1, -1, () );
    }

    $dbh->disconnect();

    my $total_time = (time() - $start_time) * 1000;
    $logger->debug(sprintf("[PERF] do_search total: %.2fms", $total_time));

    return ( $total, $filtered, @ids );
}

# Main search logic using Postgres
# Returns ($filtered_count, @ids)
sub search_postgres_with_dbh ( $dbh, $category_id, $filter, $sortkey, $sortorder, $newonly, $untaggedonly, $grouptanks, $start, $keysperpage ) {

    my $logger = get_logger( "PgSearch Core", "lanraragi" );

    # Compute search filters
    my $token_start = time();
    my @tokens = compute_search_filter($filter);
    my $token_time = (time() - $token_start) * 1000;
    $logger->debug(sprintf("[PERF] Token computation: %.2fms (token_count: %d)", $token_time, scalar @tokens));

    # Build the SQL query
    my @where_clauses = ();
    my @params = ();
    my @lateral_params = ();  # Separate array for LATERAL JOIN parameters

    # Tank grouping: When grouptanks=true, we want to return tank IDs and standalone archives.
    # When grouptanks=false, we want to return individual archives excluding those in tanks.
    if ($grouptanks) {
        # When grouping tanks, exclude archives that are members of tanks
        push @where_clauses, "NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = a.arcid)";
    }

    # Category filter
    if ( $category_id && $category_id ne "" ) {
        my $cat_start = time();
        my %category = LANraragi::Model::PsilabsDev::PgCategory::get_category($category_id);
        my $cat_time = (time() - $cat_start) * 1000;
        $logger->debug(sprintf("[PERF] Category lookup: %.2fms", $cat_time));

        if (%category) {
            if ( $category{search} && $category{search} ne "" ) {
                # Dynamic category - add its search predicate to tokens
                my @cat_tokens = compute_search_filter( $category{search} );
                push @tokens, @cat_tokens;
            } else {
                # Static category - filter by category membership
                push @where_clauses, "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ? AND arcid = a.arcid)";
                push @params, $category_id;
            }
        }
    }

    # New filter
    if ($newonly) {
        push @where_clauses, "a.isnew = TRUE";
    }

    # Untagged filter - archives with no "meaningful" tags
    # Excludes basic metadata namespaces that don't count as "tagged"
    # (matches logic in PgArchive::get_untagged_archives and Model::Stats)
    if ($untaggedonly) {
        push @where_clauses, "NOT EXISTS (
        SELECT 1 FROM lrr_archive_to_tag_map atm
        INNER JOIN lrr_tag t ON atm.tagid = t.tagid
        WHERE atm.arcid = a.arcid
        AND t.namespace NOT IN ('artist', 'parody', 'series', 'language', 'event', 'group', 'date_added', 'timestamp', 'source')
    )";
    }

    # Process search tokens
    foreach my $token (@tokens) {
        my $tag     = $token->{tag};
        my $isneg   = $token->{isneg};
        my $isexact = $token->{isexact};

        $logger->debug("Searching for $tag, isneg=$isneg, isexact=$isexact");

        # Handle pagecount/read searches: pages:20, pages:>20, read:>0, etc.
        if ( $tag =~ /^(read|pages):(>|<|>=|<=)?(\d+)$/ ) {
            my $col      = $1;
            my $operator = $2 || "=";
            my $value    = $3;

            # Map column names
            $col = $col eq "pages" ? "pagecount" : "progress";

            my $clause = "a.$col $operator ?";
            if ($isneg) {
                $clause = "NOT ($clause)";
            }
            push @where_clauses, $clause;
            push @params, $value;
            next;
        }

        # Tag-based search
        # For exact matches, we need exact namespace:value match
        # For non-exact, we use ILIKE for partial matching

        my ($namespace, $value);
        if ( $tag =~ /^([^:]+):(.*)$/ ) {
            $namespace = $1;
            $value = $2;
        } else {
            $namespace = undef;
            $value = $tag;
        }

        # Check if this looks like an archive ID (40-char hex string)
        # Archive IDs need direct matching since FTS tokenizes them poorly
        if (!defined $namespace && $value =~ /^[a-f0-9]{40}$/i) {
            my $tag_clause = "a.arcid = ?";
            if ($isneg) {
                $tag_clause = "a.arcid != ?";
            }
            push @where_clauses, $tag_clause;
            push @params, lc($value);  # arcids are lowercase in DB
            next;
        }

        # Convert wildcards: ? to _, * to %
        if (defined $namespace) {
            $namespace =~ s/\?/_/g;
            $namespace =~ s/\*/%/g;
        }
        $value =~ s/\?/_/g;
        $value =~ s/\*/%/g;

        my $tag_clause;
        if ($isexact) {
            # Exact match
            if (defined $namespace) {
                # Handle namespace-only search (e.g., "date_uploaded:")
                if ($value eq "") {
                    # Search for ANY tag with this namespace
                    $tag_clause = "EXISTS (
                        SELECT 1 FROM lrr_archive_to_tag_map atm
                        JOIN lrr_tag t ON atm.tagid = t.tagid
                        WHERE atm.arcid = a.arcid
                        AND t.namespace = ?
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, $namespace;
                } else {
                    # Search for specific namespace:value
                    $tag_clause = "EXISTS (
                        SELECT 1 FROM lrr_archive_to_tag_map atm
                        JOIN lrr_tag t ON atm.tagid = t.tagid
                        WHERE atm.arcid = a.arcid
                        AND t.namespace = ?
                        AND t.value = ?
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, $namespace, $value;
                }
            } else {
                # No namespace - match tag value or archive title
                # Check if value contains wildcards (already converted from ? to _ and * to %)
                if ($value =~ /[%_]/) {
                    # Wildcard exact search - use ILIKE for case-insensitive pattern matching, include title
                    $tag_clause = "(
                        a.title ILIKE ?
                        OR EXISTS (
                            SELECT 1 FROM lrr_archive_to_tag_map atm
                            JOIN lrr_tag t ON atm.tagid = t.tagid
                            WHERE atm.arcid = a.arcid
                            AND t.value ILIKE ?
                        )
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, $value, $value;
                } else {
                    # No wildcards - exact match on tag value or title (case-insensitive)
                    $tag_clause = "(
                        LOWER(a.title) = ?
                        OR EXISTS (
                            SELECT 1 FROM lrr_archive_to_tag_map atm
                            JOIN lrr_tag t ON atm.tagid = t.tagid
                            WHERE atm.arcid = a.arcid
                            AND t.value = ?
                        )
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, $value, $value;
                }
            }
        } else {
            # Partial match using ILIKE
            if (defined $namespace) {
                # Determine if namespace contains wildcards (already converted from * and ? to % and _)
                # If wildcards present: use ILIKE with namespace as-is
                # If no wildcards: use exact match (ILIKE without adding wildcards)
                my $namespace_has_wildcards = ($namespace =~ /[%_]/);
                my $namespace_param = $namespace_has_wildcards ? $namespace : $namespace;

                # Handle namespace-only search (e.g., "date_uploaded:")
                if ($value eq "") {
                    # Search for ANY tag with this namespace
                    $tag_clause = "EXISTS (
                        SELECT 1 FROM lrr_archive_to_tag_map atm
                        JOIN lrr_tag t ON atm.tagid = t.tagid
                        WHERE atm.arcid = a.arcid
                        AND t.namespace ILIKE ?
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, $namespace_param;
                } else {
                    # Search for namespace (exact unless wildcards) and value (fuzzy)
                    $tag_clause = "EXISTS (
                        SELECT 1 FROM lrr_archive_to_tag_map atm
                        JOIN lrr_tag t ON atm.tagid = t.tagid
                        WHERE atm.arcid = a.arcid
                        AND t.namespace ILIKE ?
                        AND t.value ILIKE ?
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, $namespace_param, "%$value%";
                }
            } else {
                # No namespace - use FTS for simple searches, ILIKE for wildcards
                # Check if value contains wildcards (before they were converted to SQL LIKE patterns)
                # We already converted ? to _ and * to %, so check for those
                if ($value =~ /[%_]/) {
                    # Wildcard search - use ILIKE (fallback for pattern matching)
                    $tag_clause = "(
                        a.title ILIKE ?
                        OR a.arcid ILIKE ?
                        OR EXISTS (
                            SELECT 1 FROM lrr_archive_to_tag_map atm
                            JOIN lrr_tag t ON atm.tagid = t.tagid
                            WHERE atm.arcid = a.arcid
                            AND (t.namespace ILIKE ? OR t.value ILIKE ?)
                        )
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, "%$value%", "%$value%", "%$value%", "%$value%";
                } else {
                    # Simple word search - use ILIKE for substring matching
                    # This handles CJK, short tokens, and numeric values correctly
                    $tag_clause = "(
                        a.title ILIKE ?
                        OR EXISTS (
                            SELECT 1 FROM lrr_archive_to_tag_map atm
                            JOIN lrr_tag t ON atm.tagid = t.tagid
                            WHERE atm.arcid = a.arcid
                            AND (t.namespace ILIKE ? OR t.value ILIKE ?)
                        )
                    )";
                    if ($isneg) {
                        $tag_clause = "NOT $tag_clause";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, "%$value%", "%$value%", "%$value%";
                }
            }
        }
    }

    # Build WHERE clause
    my $where_sql = "";
    if (@where_clauses) {
        $where_sql = "WHERE " . join( " AND ", @where_clauses );
    }

    # Build JOIN for tag-based sorting
    # Using DISTINCT ON to efficiently get one tag value per archive
    # This is much faster than LATERAL JOIN which executes for every archive row
    my $lateral_join_sql = "";
    my $use_lateral_sort = 0;
    if ( $sortkey && $sortkey ne "title" && $sortkey ne "lastread" ) {
        # Validate sortkey to prevent SQL injection (whitelist alphanumeric, underscore, hyphen)
        if ( $sortkey !~ /^[a-zA-Z0-9_-]+$/ ) {
            $logger->warn("Invalid sortkey: $sortkey. Falling back to title sort.");
        } else {
            # Use LEFT JOIN with DISTINCT ON - filter tags by namespace first, then join to archives
            # This reverses the join order and is much faster than LATERAL JOIN
            $lateral_join_sql = "LEFT JOIN (
                SELECT DISTINCT ON (atm.arcid) atm.arcid, t.value as sort_value
                FROM lrr_tag t
                JOIN lrr_archive_to_tag_map atm ON t.tagid = atm.tagid
                WHERE t.namespace = ?
                ORDER BY atm.arcid, t.value DESC
            ) sort_tag ON sort_tag.arcid = a.arcid";
            push @lateral_params, $sortkey;  # Add to lateral_params instead of params
            $use_lateral_sort = 1;
        }
    }

    # Build ORDER BY clause
    my $order_sql = "";
    if ( !$sortkey || $sortkey eq "title" ) {
        $order_sql = "ORDER BY a.title" . ( $sortorder ? " DESC" : " ASC" );
    } elsif ( $sortkey eq "lastread" ) {
        $order_sql = "ORDER BY a.lastreadtime" . ( $sortorder ? " DESC" : " ASC" );
    } else {
        # Sort by tag namespace value (using LATERAL JOIN result)
        if ($use_lateral_sort) {
            $order_sql = "ORDER BY COALESCE(sort_tag.sort_value, 'zzzzzzzzzz')" . ( $sortorder ? " DESC" : " ASC" ) . ", a.title ASC";
        } else {
            # Fallback to title sort if sortkey was invalid
            $order_sql = "ORDER BY a.title" . ( $sortorder ? " DESC" : " ASC" );
        }
    }

    # Get total count of matching archives (without pagination)
    # NOTE: COUNT query does not need LATERAL JOIN (only used for sorting)
    my $count_sql = "SELECT COUNT(*) as total FROM lrr_archive a $where_sql";
    $logger->debug("COUNT SQL: $count_sql");
    my $count_start = time();
    my $count_sth = $dbh->prepare($count_sql);
    $count_sth->execute(@params);
    my $archive_filtered_count = $count_sth->fetchrow_hashref->{total} || 0;
    $count_sth->finish;
    my $count_time = (time() - $count_start) * 1000;
    $logger->debug(sprintf("[PERF] Filtered COUNT query: %.2fms", $count_time));

    # Build LIMIT/OFFSET clause
    my $limit_sql = "";
    my @limit_params = ();
    if ( defined $start && defined $keysperpage && $keysperpage > 0 ) {
        $limit_sql = "LIMIT ? OFFSET ?";
        push @limit_params, $keysperpage, $start;
    }

    # Build final SQL with pagination
    my $sql = "SELECT a.arcid FROM lrr_archive a $lateral_join_sql $where_sql $order_sql $limit_sql";

    $logger->debug("SQL: $sql");
    $logger->debug("LATERAL params: " . join(", ", @lateral_params));
    $logger->debug("WHERE params: " . join(", ", @params));
    $logger->debug("LIMIT params: " . join(", ", @limit_params));

    my $select_start = time();
    my $sth = $dbh->prepare($sql);
    # Execute with LATERAL params first (appear first in SQL), then WHERE params, then LIMIT params
    $sth->execute(@lateral_params, @params, @limit_params);

    my @ids;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @ids, $row->{arcid};
    }
    $sth->finish;
    my $select_time = (time() - $select_start) * 1000;

    # Determine sort type for logging
    my $sort_desc = $sortkey || "title";
    if ($sortkey && $sortkey ne "title" && $sortkey ne "lastread" && $use_lateral_sort) {
        $sort_desc = "tag:$sortkey";
    }

    $logger->debug(sprintf("[PERF] Results SELECT query: %.2fms (sort: %s, lateral_join: %s, limit: %s, offset: %s)",
        $select_time,
        $sort_desc,
        $use_lateral_sort ? 'true' : 'false',
        defined $keysperpage ? $keysperpage : 'none',
        defined $start ? $start : 'none'));

    # When grouptanks=true, we also need to fetch tank IDs that match the search criteria
    # and prepend them to the results (tanks typically come first)
    my $tank_filtered_count = 0;
    if ($grouptanks) {
        my $tank_start = time();
        my ( $tank_count, @tank_ids ) = search_tanks_postgres_with_dbh($dbh, $category_id, $filter, $sortkey, $sortorder, $start, $keysperpage);
        my $tank_time = (time() - $tank_start) * 1000;
        $logger->debug(sprintf("[PERF] Tank search: %.2fms", $tank_time));
        $tank_filtered_count = $tank_count;
        if (@tank_ids) {
            $logger->debug( "Found " . scalar @tank_ids . " tank results (paginated)" );
            # Prepend tank IDs to archive IDs
            unshift @ids, @tank_ids;
        }
    }

    my $total_filtered = $archive_filtered_count + $tank_filtered_count;
    $logger->debug( "Found $total_filtered total filtered results, returning " . scalar @ids . " paginated results" );

    return ( $total_filtered, @ids );
}

# Search for tanks matching the given criteria
# Returns ($filtered_count, @tank_ids)
sub search_tanks_postgres_with_dbh ( $dbh, $category_id, $filter, $sortkey, $sortorder, $start, $keysperpage ) {

    my $logger = get_logger( "PgSearch Tank", "lanraragi" );

    # Compute search filters
    my @tokens = compute_search_filter($filter);

    # Build the SQL query for tanks
    my @where_clauses = ();
    my @params = ();

    # Category filter for tanks
    # Note: Tanks can be in categories through lrr_category_to_archive_map using their tankid
    if ( $category_id && $category_id ne "" ) {
        my %category = LANraragi::Model::PsilabsDev::PgCategory::get_category($category_id);

        if (%category) {
            if ( $category{search} && $category{search} ne "" ) {
                # Dynamic category - add its search predicate to tokens
                my @cat_tokens = compute_search_filter( $category{search} );
                push @tokens, @cat_tokens;
            } else {
                # Static category - filter by category membership
                # Tanks can be in categories directly
                push @where_clauses, "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ? AND arcid = t.tankid)";
                push @params, $category_id;
            }
        }
    }

    # Process search tokens for tanks
    foreach my $token (@tokens) {
        my $tag     = $token->{tag};
        my $isneg   = $token->{isneg};
        my $isexact = $token->{isexact};

        $logger->debug("Tank search for $tag, isneg=$isneg, isexact=$isexact");

        # Skip page/read count searches for tanks (they don't have pagecount/progress)
        if ( $tag =~ /^(read|pages):/ ) {
            next;
        }

        # Tag-based search for tanks
        my ($namespace, $value);
        if ( $tag =~ /^([^:]+):(.*)$/ ) {
            $namespace = $1;
            $value = $2;
        } else {
            $namespace = undef;
            $value = $tag;
        }

        # Convert wildcards: ? to _, * to %
        if (defined $namespace) {
            $namespace =~ s/\?/_/g;
            $namespace =~ s/\*/%/g;
        }
        $value =~ s/\?/_/g;
        $value =~ s/\*/%/g;

        my $tag_clause;
        if ($isexact) {
            # Exact match - search in tank name or tags field
            if (defined $namespace) {
                # For tanks, tags are stored as a text field, so we search within it
                # Handle namespace-only search (e.g., "date_uploaded:")
                if ($value eq "") {
                    # Search for ANY tag with this namespace
                    $tag_clause = "t.tags LIKE ?";
                    if ($isneg) {
                        $tag_clause = "NOT ($tag_clause)";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, "%$namespace:%";
                } else {
                    # Search for specific namespace:value
                    $tag_clause = "t.tags LIKE ?";
                    if ($isneg) {
                        $tag_clause = "NOT ($tag_clause)";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, "%$namespace:$value%";
                }
            } else {
                # No namespace - match in name or tags (tank IDs searchable via partial search)
                $tag_clause = "(t.name = ? OR t.tags LIKE ?)";
                if ($isneg) {
                    $tag_clause = "NOT $tag_clause";
                }
                push @where_clauses, $tag_clause;
                push @params, $value, "%$value%";
            }
        } else {
            # Partial match using ILIKE
            if (defined $namespace) {
                # Handle namespace-only search (e.g., "date_uploaded:")
                if ($value eq "") {
                    # Search for ANY tag with this namespace (partial namespace match)
                    $tag_clause = "t.tags ILIKE ?";
                    if ($isneg) {
                        $tag_clause = "NOT ($tag_clause)";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, "%$namespace:%";
                } else {
                    # Search for namespace and value (both partial match)
                    $tag_clause = "t.tags ILIKE ?";
                    if ($isneg) {
                        $tag_clause = "NOT ($tag_clause)";
                    }
                    push @where_clauses, $tag_clause;
                    push @params, "%$namespace%$value%";
                }
            } else {
                # No namespace - search in tank ID, name, summary, or tags
                $tag_clause = "(
                    t.tankid ILIKE ?
                    OR t.name ILIKE ?
                    OR t.summary ILIKE ?
                    OR t.tags ILIKE ?
                )";
                if ($isneg) {
                    $tag_clause = "NOT $tag_clause";
                }
                push @where_clauses, $tag_clause;
                push @params, "%$value%", "%$value%", "%$value%", "%$value%";
            }
        }
    }

    # Build WHERE clause
    my $where_sql = "";
    if (@where_clauses) {
        $where_sql = "WHERE " . join( " AND ", @where_clauses );
    }

    # Build ORDER BY clause for tanks
    my $order_sql = "";
    if ( !$sortkey || $sortkey eq "title" ) {
        $order_sql = "ORDER BY t.name" . ( $sortorder ? " DESC" : " ASC" );
    } elsif ( $sortkey eq "lastread" ) {
        # Tanks don't have lastreadtime, so we just order by name
        $order_sql = "ORDER BY t.name" . ( $sortorder ? " DESC" : " ASC" );
    } else {
        # Sort by tag namespace - search within tags field
        # Since tanks store tags as text, we can't sort by specific namespace easily
        # Just fall back to name sorting
        $order_sql = "ORDER BY t.name" . ( $sortorder ? " DESC" : " ASC" );
    }

    # Get total count of matching tanks (without pagination)
    my $count_sql = "SELECT COUNT(*) as total FROM lrr_tank t $where_sql";
    $logger->debug("Tank COUNT SQL: $count_sql");
    my $count_start = time();
    my $count_sth = $dbh->prepare($count_sql);
    $count_sth->execute(@params);
    my $tank_filtered_count = $count_sth->fetchrow_hashref->{total} || 0;
    $count_sth->finish;
    my $count_time = (time() - $count_start) * 1000;
    $logger->debug(sprintf("[PERF] Tank COUNT query: %.2fms", $count_time));

    # Build LIMIT/OFFSET clause
    my $limit_sql = "";
    my @limit_params = ();
    if ( defined $start && defined $keysperpage && $keysperpage > 0 ) {
        $limit_sql = "LIMIT ? OFFSET ?";
        push @limit_params, $keysperpage, $start;
    }

    # Build final SQL for tanks with pagination
    my $sql = "SELECT t.tankid FROM lrr_tank t $where_sql $order_sql $limit_sql";

    $logger->debug("Tank SQL: $sql");
    $logger->debug("Tank Params: " . join(", ", @params));
    $logger->debug("Tank LIMIT params: " . join(", ", @limit_params));

    my $select_start = time();
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params, @limit_params);

    my @tank_ids;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @tank_ids, $row->{tankid};
    }
    $sth->finish;
    my $select_time = (time() - $select_start) * 1000;
    $logger->debug(sprintf("[PERF] Tank SELECT query: %.2fms (limit: %s, offset: %s)",
        $select_time,
        defined $keysperpage ? $keysperpage : 'none',
        defined $start ? $start : 'none'));

    return ( $tank_filtered_count, @tank_ids );
}

# replaces LANraragi::Model::Search::compute_search_filter
# Transform the search engine syntax into a list of tokens.
sub compute_search_filter ($filter) {

    my $logger = get_logger( "PgSearch Core", "lanraragi" );
    my @tokens = ();
    if ( !$filter ) { $filter = ""; }

    # Special characters:
    # "" for exact search (or $, but is that one really useful now?)
    # ?/_ for any character
    # * % for multiple characters
    # - to exclude the next tag

    my $b = reverse($filter);
    while ( $b ne "" ) {

        my $char  = chop $b;
        my $isneg = 0;

        # Skip spaces
        while ( $char eq " " && $b ne "" ) {
            $char = chop $b;
        }

        if ( $char eq "-" ) {
            $isneg = 1;
            $char  = chop $b;
        }

        # Get characters until the next comma, or the next " if the following char is "
        my $delimiter = ',';
        if ( $char eq '"' ) {
            $delimiter = '"';
            $char      = chop $b;
        }

        my $tag     = "";
        my $isexact = 0;
      TAGBUILD: while (1) {
            if ( $char eq $delimiter || $char eq "" ) { last TAGBUILD; }
            $tag  = $tag . $char;    # Add characters in reverse order since we used reverse earlier on
            $char = chop $b;
        }

        # If last char is $ or delimiter was ", enable isexact
        if ( $delimiter eq '"' ) {
            $isexact = 1;

            # Quotes then $ is an accepted syntax, even though it does nothing
            $char = chop $b;
            unless ( $char eq "\$" ) {
                $b = $b . $char;
            }
        } else {
            $char = chop $tag;
            if ( $char eq "\$" ) {
                $isexact = 1;
            } else {
                $tag = $tag . $char;
            }
        }

        $logger->debug("Pre-trim tag: $tag");
        $tag = trim($tag);

        if ( $tag ne "" ) {    # Blank tokens shouldn't be added as they'll slow down search
            push @tokens,
              { tag     => lc($tag),
                isneg   => $isneg,
                isexact => $isexact
              };
        }
    }
    return @tokens;
}

1;
