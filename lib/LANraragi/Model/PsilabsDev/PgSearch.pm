package LANraragi::Model::PsilabsDev::PgSearch;

use feature qw(signatures);
no warnings 'experimental::signatures';

use strict;
use warnings;
use utf8;

use List::Util qw(min);
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

    eval {
        # Get total count of archives
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

        # Perform the search
        @ids = search_postgres(
            $dbh, $category_id, $filter, $sortkey, $sortorder,
            $newonly, $untaggedonly, $grouptanks
        );

        $filtered = scalar @ids;
    };

    if ( my $error = $@ ) {
        $logger->error("Search error: $error");
        $dbh->disconnect();
        return ( -1, -1, () );
    }

    $dbh->disconnect();

    # If start is negative, return all possible data
    if ( $start == -1 ) {
        return ( $total, $filtered, @ids );
    }

    # Only get the first X keys
    my $keysperpage = LANraragi::Model::Config->get_pagesize;

    # Return total keys and the filtered ones
    my $end = min( $start + $keysperpage - 1, $#ids );
    if ( $end < $start ) {
        return ( $total, $filtered, () );
    }
    return ( $total, $filtered, @ids[ $start .. $end ] );
}

# Main search logic using Postgres
sub search_postgres ( $dbh, $category_id, $filter, $sortkey, $sortorder, $newonly, $untaggedonly, $grouptanks ) {

    my $logger = get_logger( "PgSearch Core", "lanraragi" );

    # Compute search filters
    my @tokens = compute_search_filter($filter);

    # Build the SQL query
    my @where_clauses = ();
    my @params = ();

    # Tank grouping: When grouptanks=true, we want to return tank IDs and standalone archives.
    # When grouptanks=false, we want to return individual archives excluding those in tanks.
    if ($grouptanks) {
        # When grouping tanks, exclude archives that are members of tanks
        push @where_clauses, "NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = a.arcid)";
    }

    # Category filter
    if ( $category_id && $category_id ne "" ) {
        my %category = LANraragi::Model::PsilabsDev::PgCategory::get_category($category_id);

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

    # Untagged filter - archives with no tags
    if ($untaggedonly) {
        push @where_clauses, "NOT EXISTS (SELECT 1 FROM lrr_archive_to_tag_map WHERE arcid = a.arcid)";
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
        if ( $tag =~ /^([^:]+):(.+)$/ ) {
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
            # Exact match
            if (defined $namespace) {
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
            } else {
                # No namespace - match tag value only (archive IDs searchable via partial search)
                $tag_clause = "EXISTS (
                    SELECT 1 FROM lrr_archive_to_tag_map atm
                    JOIN lrr_tag t ON atm.tagid = t.tagid
                    WHERE atm.arcid = a.arcid
                    AND t.value = ?
                )";
                if ($isneg) {
                    $tag_clause = "NOT $tag_clause";
                }
                push @where_clauses, $tag_clause;
                push @params, $value;
            }
        } else {
            # Partial match using ILIKE
            if (defined $namespace) {
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
                push @params, "%$namespace%", "%$value%";
            } else {
                # No namespace - search in title, archive ID, and tag values
                # Use title search OR archive ID search OR tag value search
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
            }
        }
    }

    # Build WHERE clause
    my $where_sql = "";
    if (@where_clauses) {
        $where_sql = "WHERE " . join( " AND ", @where_clauses );
    }

    # Build ORDER BY clause
    my $order_sql = "";
    if ( !$sortkey || $sortkey eq "title" ) {
        $order_sql = "ORDER BY a.title" . ( $sortorder ? " DESC" : " ASC" );
    } elsif ( $sortkey eq "lastread" ) {
        $order_sql = "ORDER BY a.lastreadtime" . ( $sortorder ? " ASC" : " DESC" );
    } else {
        # Sort by a specific tag namespace
        # Validate sortkey to prevent SQL injection (whitelist alphanumeric, underscore, hyphen)
        if ( $sortkey !~ /^[a-zA-Z0-9_-]+$/ ) {
            $logger->warn("Invalid sortkey: $sortkey. Falling back to title sort.");
            $order_sql = "ORDER BY a.title" . ( $sortorder ? " DESC" : " ASC" );
        } else {
            # This is more complex - we need to join with tags and order by the tag value
            $order_sql = "ORDER BY (
                SELECT t.value
                FROM lrr_archive_to_tag_map atm
                JOIN lrr_tag t ON atm.tagid = t.tagid
                WHERE atm.arcid = a.arcid
                AND t.namespace = ?
                LIMIT 1
            )" . ( $sortorder ? " DESC" : " ASC" ) . " NULLS LAST, a.title ASC";
            push @params, $sortkey;
        }
    }

    # Build final SQL
    my $sql = "SELECT a.arcid FROM lrr_archive a $where_sql $order_sql";

    $logger->debug("SQL: $sql");
    $logger->debug("Params: " . join(", ", @params));

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my @ids;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @ids, $row->{arcid};
    }
    $sth->finish;

    # When grouptanks=true, we also need to fetch tank IDs that match the search criteria
    # and prepend them to the results (tanks typically come first)
    if ($grouptanks) {
        my @tank_ids = search_tanks_postgres($dbh, $category_id, $filter, $sortkey, $sortorder);
        if (@tank_ids) {
            $logger->debug( "Found " . scalar @tank_ids . " tank results" );
            # Prepend tank IDs to archive IDs
            unshift @ids, @tank_ids;
        }
    }

    $logger->debug( "Found " . scalar @ids . " total results" );

    return @ids;
}

# Search for tanks matching the given criteria
# Returns a list of tank IDs
sub search_tanks_postgres ( $dbh, $category_id, $filter, $sortkey, $sortorder ) {

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
                # Dynamic category - search predicate is already in tokens
                # No additional filtering needed here
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
        if ( $tag =~ /^([^:]+):(.+)$/ ) {
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
                $tag_clause = "t.tags LIKE ?";
                if ($isneg) {
                    $tag_clause = "NOT ($tag_clause)";
                }
                push @where_clauses, $tag_clause;
                push @params, "%$namespace:$value%";
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
                $tag_clause = "t.tags ILIKE ?";
                if ($isneg) {
                    $tag_clause = "NOT ($tag_clause)";
                }
                push @where_clauses, $tag_clause;
                push @params, "%$namespace%$value%";
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

    # Build final SQL for tanks
    my $sql = "SELECT t.tankid FROM lrr_tank t $where_sql $order_sql";

    $logger->debug("Tank SQL: $sql");
    $logger->debug("Tank Params: " . join(", ", @params));

    my $sth = $dbh->prepare($sql);
    $sth->execute(@params);

    my @tank_ids;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @tank_ids, $row->{tankid};
    }
    $sth->finish;

    return @tank_ids;
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
