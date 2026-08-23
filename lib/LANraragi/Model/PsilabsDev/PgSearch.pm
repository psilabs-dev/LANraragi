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
use LANraragi::Utils::PsilabsDev::Database qw(get_dbh);
use LANraragi::Model::Config;
use LANraragi::Model::PsilabsDev::PgCategory;

# ---------------------------------------------------------------------------
# API facade
#
# Every public search runs through do_clause_search: a plain search is the
# collapsed single-clause case, a composite search is several OR-composed
# clauses. Existing endpoints therefore exercise the same statement builders
# and query paths as the composite API.
# ---------------------------------------------------------------------------

# replaces LANraragi::Model::Search::do_search
# Returns ($total, $filtered, @ids)
sub do_search ( $filter, $category_id, $start, $sortkey, $sortorder, $newonly, $untaggedonly, $grouptanks, $hidecompleted ) {

    my @tokens = compute_search_filter($filter);
    my $clause = {
        tokens        => \@tokens,
        categories    => ( $category_id && $category_id ne "" ) ? [ { id => $category_id, mode => "include" } ] : [],
        newonly       => $newonly       ? 1 : 0,
        untaggedonly  => $untaggedonly  ? 1 : 0,
        hidecompleted => $hidecompleted ? 1 : 0,
    };
    return do_clause_search( [$clause], $start, $sortkey, $sortorder, $grouptanks );
}

# replaces LANraragi::Model::Search::do_composite_search
# Clause descriptors follow the composite API shape:
#   { filter => "...", categories => [ { id => ..., mode => "include"|"exclude" } ], newonly => ..., ... }
# Returns ($total, $filtered, @ids)
sub do_composite_search ( $clause_descriptors, $start, $sortkey, $sortorder, $grouptanks ) {

    my $descriptors = $clause_descriptors // [];

    # Normalize each descriptor with canonical token/category keys so
    # reduce_clauses can compare them. newonly/untaggedonly are tri-state
    # (1 = only, -1 = exclude, 0 = off), matching the Redis contract.
    my @normed;
    foreach my $desc (@$descriptors) {
        my @tokens       = compute_search_filter( $desc->{filter} // "" );
        my @canon_tokens = sort map { join( "|", $_->{tag}, $_->{isneg}, $_->{isexact} ) } @tokens;
        my @canon_cats   = sort map { ( $_->{id} // "" ) . ":" . ( $_->{mode} // "include" ) } @{ $desc->{categories} // [] };
        push @normed,
          {
            categories    => $desc->{categories} // [],
            tokens        => \@tokens,
            canon_tokens  => \@canon_tokens,
            canon_cats    => \@canon_cats,
            newonly       => 0 + ( $desc->{newonly}      // 0 ),
            untaggedonly  => 0 + ( $desc->{untaggedonly} // 0 ),
            hidecompleted => $desc->{hidecompleted} ? 1 : 0,
          };
    }

    return do_clause_search( reduce_clauses( \@normed ), $start, $sortkey, $sortorder, $grouptanks );
}

# Drop clauses subsumed by a less-restrictive clause (DNF absorption), so a
# redundant OR arm never reaches SQL. Same semantics as dev-search's
# Utils::Search::reduce_clauses, keyed on this module's own token parse.
sub reduce_clauses ($normed) {

    return $normed if scalar @$normed <= 1;

    # Pairwise absorption: if A subsumes B, remove B.
    # A subsumes B when A's predicates are a subset of B's (A is less restrictive).
    # Identical clauses mutually subsume, so dedup is handled implicitly.
    my @keep = (1) x scalar @$normed;
    for my $i ( 0 .. $#$normed ) {
        next unless $keep[$i];
        for my $j ( 0 .. $#$normed ) {
            next if $i == $j;
            next unless $keep[$j];

            my ( $a, $b ) = ( $normed->[$i], $normed->[$j] );

            # Flag subsumption: 0 (off) subsumes any value; set flags must match.
            my $subsumes = 1;
            for my $flag (qw(newonly untaggedonly hidecompleted)) {
                unless ( $a->{$flag} == 0 || $a->{$flag} == $b->{$flag} ) {
                    $subsumes = 0;
                    last;
                }
            }

            # A's tokens must be a subset of B's tokens
            if ($subsumes) {
                my %b_tokens = map { $_ => 1 } @{ $b->{canon_tokens} };
                for my $t ( @{ $a->{canon_tokens} } ) {
                    unless ( $b_tokens{$t} ) {
                        $subsumes = 0;
                        last;
                    }
                }
            }

            # A's categories must be a subset of B's categories
            if ($subsumes) {
                my %b_cats = map { $_ => 1 } @{ $b->{canon_cats} };
                for my $c ( @{ $a->{canon_cats} } ) {
                    unless ( $b_cats{$c} ) {
                        $subsumes = 0;
                        last;
                    }
                }
            }

            $keep[$j] = 0 if $subsumes;
        }
    }

    return [ map { $normed->[$_] } grep { $keep[$_] } 0 .. $#$normed ];
}

# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

# Run a clause set as one archive statement (plus one tank statement when
# grouping): each clause is an AND-group of predicates, clauses OR together.
# Returns ($total, $filtered, @ids); ( -1, -1 ) on error.
sub do_clause_search ( $clauses, $start, $sortkey, $sortorder, $grouptanks ) {

    my $logger = get_logger( "PgSearch Engine", "lanraragi" );
    my $dbh = get_dbh();

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

        # An empty clause set matches nothing (parity with the Redis composite
        # implementation, which unions zero clauses into an empty result).
        unless (@$clauses) {
            $filtered = 0;
            return;
        }

        # Determine pagination parameters
        my $keysperpage = LANraragi::Model::Config->get_pagesize;
        my $use_pagination = ( $start != -1 );
        my $q_start = $use_pagination ? $start       : undef;
        my $q_limit = $use_pagination ? $keysperpage : undef;

        # Resolved inside the eval: DB errors return ( -1, -1 ); an unknown
        # category resolves to no constraint.
        my @resolved;
        foreach my $clause (@$clauses) {
            my @constraints;
            foreach my $cat_entry ( @{ $clause->{categories} // [] } ) {
                my $constraint = category_entry_to_constraint( $cat_entry->{id}, $cat_entry->{mode} // "include" );
                push @constraints, $constraint if $constraint;
            }
            push @resolved, { %$clause, constraints => \@constraints };
        }

        # Prep and run the archive statement
        my ( $where_sql, @params ) = compose_where_sql(
            map { [ build_archive_where_clauses( $_->{tokens}, $_->{constraints}, $_->{newonly}, $_->{untaggedonly}, $_->{hidecompleted}, $grouptanks ) ] } @resolved );

        my $search_start = time();
        my $archive_filtered;
        ( $archive_filtered, @ids ) = search_archives_with_dbh( $dbh, $where_sql, \@params, $sortkey, $sortorder, $q_start, $q_limit );
        my $search_time = (time() - $search_start) * 1000;
        $logger->debug(sprintf("[PERF] Archive search: %.2fms", $search_time));
        $filtered = $archive_filtered;

        # When grouptanks=true, we also need to fetch tank IDs that match the search
        # criteria and prepend them to the results (tanks typically come first)
        if ($grouptanks) {
            my ( $tank_where_sql, @tank_params ) = compose_where_sql(
                map { [ build_tank_where_clauses( $_->{tokens}, $_->{constraints} ) ] } @resolved );

            my $tank_start = time();
            my ( $tank_filtered, @tank_ids ) = search_tanks_with_dbh( $dbh, $tank_where_sql, \@tank_params, $sortkey, $sortorder, $q_start, $q_limit );
            my $tank_time = (time() - $tank_start) * 1000;
            $logger->debug(sprintf("[PERF] Tank search: %.2fms", $tank_time));
            $filtered += $tank_filtered;
            if (@tank_ids) {
                $logger->debug( "Found " . scalar @tank_ids . " tank results (paginated)" );
                unshift @ids, @tank_ids;
            }
        }

        $logger->debug( "Found $filtered total filtered results, returning " . scalar @ids . " paginated results" );
    };

    if ( my $error = $@ ) {
        $logger->error("Search error: $error");
        $dbh->disconnect();
        return ( -1, -1, () );
    }

    $dbh->disconnect();

    my $total_time = (time() - $start_time) * 1000;
    $logger->debug(sprintf("[PERF] do_clause_search total: %.2fms", $total_time));

    return ( $total, $filtered, @ids );
}

# ---------------------------------------------------------------------------
# Statement prep
# ---------------------------------------------------------------------------

# Compose per-clause fragment groups into one WHERE clause: fragments AND
# within a clause, clauses OR together. A clause with no predicates matches
# everything, which collapses the whole statement to an empty WHERE.
sub compose_where_sql (@groups) {

    my @clause_sql;
    my @params;
    foreach my $group (@groups) {
        my ( $where, $group_params ) = @$group;
        return ( "", () ) unless @$where;
        push @clause_sql, $where;
        push @params, @$group_params;
    }
    return ( "", () ) unless @clause_sql;

    if ( scalar @clause_sql == 1 ) {
        return ( "WHERE " . join( " AND ", @{ $clause_sql[0] } ), @params );
    }
    return ( "WHERE " . join( " OR ", map { "(" . join( " AND ", @$_ ) . ")" } @clause_sql ), @params );
}

# Resolve one category reference + mode into a constraint descriptor: static
# categories constrain by membership map, dynamic categories by the tokens of
# their stored search predicate.
sub category_entry_to_constraint ( $category_id, $mode ) {

    return unless $category_id && $category_id ne "";
    my %category = LANraragi::Model::PsilabsDev::PgCategory::get_category($category_id);
    return unless %category;

    if ( $category{search} && $category{search} ne "" ) {
        my @cat_tokens = compute_search_filter( $category{search} );
        return { mode => $mode, tokens => \@cat_tokens };
    }
    return { mode => $mode, id => $category_id };
}

# Translate one clause (tokens + category constraints + flags) into WHERE
# fragments and bind parameters for the archive table (alias "a").
sub build_archive_where_clauses ( $tokens_in, $constraints, $newonly, $untaggedonly, $hidecompleted, $grouptanks ) {

    my $logger = get_logger( "PgSearch Core", "lanraragi" );
    my @tokens = @$tokens_in;
    my @where_clauses = ();
    my @params = ();

    # Tank grouping: When grouptanks=true, we want to return tank IDs and standalone archives.
    # When grouptanks=false, we want to return individual archives excluding those in tanks.
    if ($grouptanks) {
        # When grouping tanks, exclude archives that are members of tanks
        push @where_clauses, "NOT EXISTS (SELECT 1 FROM lrr_tank_to_archive_map WHERE arcid = a.arcid)";
    }

    # Category constraints
    foreach my $constraint (@$constraints) {
        my $exclude = ( $constraint->{mode} // "include" ) eq "exclude";
        if ( $constraint->{tokens} ) {
            if ($exclude) {
                # Dynamic exclude: negate the category's whole token conjunction.
                my ( $sub_where, $sub_params ) = build_archive_where_clauses( $constraint->{tokens}, [], 0, 0, 0, 0 );
                next unless @$sub_where;
                push @where_clauses, "NOT (" . join( " AND ", @$sub_where ) . ")";
                push @params, @$sub_params;
            } else {
                # Dynamic include: the category's tokens join the clause's own.
                push @tokens, @{ $constraint->{tokens} };
            }
        } else {
            # Static category - filter by category membership
            my $membership = "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ? AND arcid = a.arcid)";
            push @where_clauses, $exclude ? "NOT $membership" : $membership;
            push @params, $constraint->{id};
        }
    }

    # New filter (tri-state: 1 = only new, -1 = exclude new, 0 = off)
    if ( $newonly && $newonly == -1 ) {
        push @where_clauses, "a.isnew = FALSE";
    } elsif ($newonly) {
        push @where_clauses, "a.isnew = TRUE";
    }

    # Hide completed archives — match upstream's >85% threshold (Model::Search::search_uncached)
    if ($hidecompleted) {
        push @where_clauses, "NOT (a.pagecount > 0 AND a.progress::float / a.pagecount > 0.85)";
    }

    # Untagged filter - archives with no "meaningful" tags
    # Excludes basic metadata namespaces that don't count as "tagged"
    # Uses denormalized namespace on tag map — no join to lrr_tag needed.
    # (tri-state: 1 = only untagged, -1 = exclude untagged, 0 = off)
    if ($untaggedonly) {
        my $has_tags = "EXISTS (
        SELECT 1 FROM lrr_archive_to_tag_map atm
        WHERE atm.arcid = a.arcid
        AND atm.namespace NOT IN ('artist', 'parody', 'series', 'language', 'event', 'group', 'date_added', 'timestamp', 'source')
    )";
        push @where_clauses, ( $untaggedonly == -1 ) ? $has_tags : "NOT $has_tags";
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
                        AND LOWER(t.namespace) = ?
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
                        AND LOWER(t.namespace) = ?
                        AND LOWER(t.value) = ?
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
                            AND LOWER(t.value) = ?
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
                    push @params, $namespace;
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
                    push @params, $namespace, "%$value%";
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

    return ( \@where_clauses, \@params );
}

# Translate one clause into WHERE fragments and bind parameters for the tank
# table (alias "t"). Tanks store tags as a flat text column, so the token
# predicates differ from the archive builder's.
sub build_tank_where_clauses ( $tokens_in, $constraints ) {

    my $logger = get_logger( "PgSearch Tank", "lanraragi" );
    my @tokens = @$tokens_in;
    my @where_clauses = ();
    my @params = ();

    # Category constraints
    # Note: Tanks can be in categories through lrr_category_to_archive_map using their tankid
    foreach my $constraint (@$constraints) {
        my $exclude = ( $constraint->{mode} // "include" ) eq "exclude";
        if ( $constraint->{tokens} ) {
            if ($exclude) {
                # Dynamic exclude: negate the category's whole token conjunction.
                my ( $sub_where, $sub_params ) = build_tank_where_clauses( $constraint->{tokens}, [] );
                next unless @$sub_where;
                push @where_clauses, "NOT (" . join( " AND ", @$sub_where ) . ")";
                push @params, @$sub_params;
            } else {
                # Dynamic include: the category's tokens join the clause's own.
                push @tokens, @{ $constraint->{tokens} };
            }
        } else {
            # Static category - filter by category membership
            # Tanks can be in categories directly
            my $membership = "EXISTS (SELECT 1 FROM lrr_category_to_archive_map WHERE catid = ? AND arcid = t.tankid)";
            push @where_clauses, $exclude ? "NOT $membership" : $membership;
            push @params, $constraint->{id};
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

    return ( \@where_clauses, \@params );
}

# ---------------------------------------------------------------------------
# Query layer
# ---------------------------------------------------------------------------

# Run the prepared archive statement: sort (including tag-namespace lateral
# sort), pagination, filtered count via window function, EXPLAIN diagnostics.
# Returns ($filtered_count, @ids)
sub search_archives_with_dbh ( $dbh, $where_sql, $params_in, $sortkey, $sortorder, $start, $keysperpage ) {

    my $logger = get_logger( "PgSearch Core", "lanraragi" );
    my @params = @$params_in;
    my @lateral_params = ();  # Separate array for LATERAL JOIN parameters

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
            # Single-table sort subquery using denormalized (namespace, value) on the tag map.
            # No join to lrr_tag needed — the covering index (namespace, arcid) INCLUDE (value)
            # services the entire subquery from a single index-only scan.
            $lateral_join_sql = "LEFT JOIN (
                SELECT atm.arcid, MAX(atm.value) as sort_value
                FROM lrr_archive_to_tag_map atm
                WHERE atm.namespace = ?
                GROUP BY atm.arcid
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
        # Partition: archives with lastreadtime > 0 first, unread archives last
        $order_sql = "ORDER BY CASE WHEN a.lastreadtime IS NULL OR a.lastreadtime = 0 THEN 1 ELSE 0 END, a.lastreadtime"
            . ( $sortorder ? " DESC" : " ASC" );
    } else {
        # Sort by tag namespace value (using LATERAL JOIN result)
        if ($use_lateral_sort) {
            # Partition: keyed archives (have sort namespace tag) first, unkeyed last
            $order_sql = "ORDER BY CASE WHEN sort_tag.sort_value IS NULL THEN 1 ELSE 0 END, sort_tag.sort_value"
                . ( $sortorder ? " DESC" : " ASC" ) . ", a.title ASC";
        } else {
            # Fallback to title sort if sortkey was invalid
            $order_sql = "ORDER BY a.title" . ( $sortorder ? " DESC" : " ASC" );
        }
    }

    # Build LIMIT/OFFSET clause
    my $limit_sql = "";
    my @limit_params = ();
    if ( defined $start && defined $keysperpage && $keysperpage > 0 ) {
        $limit_sql = "LIMIT ? OFFSET ?";
        push @limit_params, $keysperpage, $start;
    }

    # Single query: SELECT with COUNT(*) OVER() to get filtered count and paginated results together.
    # This avoids running the filter twice (once for COUNT, once for SELECT).
    my $sql = "SELECT a.arcid, COUNT(*) OVER() as filtered_total FROM lrr_archive a $lateral_join_sql $where_sql $order_sql $limit_sql";

    $logger->debug("SQL: $sql");
    $logger->debug("LATERAL params: " . join(", ", @lateral_params));
    $logger->debug("WHERE params: " . join(", ", @params));
    $logger->debug("LIMIT params: " . join(", ", @limit_params));

    my $select_start = time();
    my $sth = $dbh->prepare($sql);
    $sth->execute(@lateral_params, @params, @limit_params);

    my @ids;
    my $archive_filtered_count = 0;
    while ( my $row = $sth->fetchrow_hashref ) {
        $archive_filtered_count = $row->{filtered_total} unless $archive_filtered_count;
        push @ids, $row->{arcid};
    }
    $sth->finish;

    # When OFFSET exceeds result count, no rows are returned and filtered_total is unknown.
    # Fall back to a COUNT query only in this edge case (paginated query with 0 results).
    if ( !$archive_filtered_count && !@ids && defined $start ) {
        my $count_sql = "SELECT COUNT(*) as total FROM lrr_archive a $where_sql";
        my $count_sth = $dbh->prepare($count_sql);
        $count_sth->execute(@params);
        $archive_filtered_count = $count_sth->fetchrow_hashref->{total} || 0;
        $count_sth->finish;
    }

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

    # EXPLAIN ANALYZE for diagnostic purposes (debug mode only)
    if ($select_time > 50) {
        eval {
            my $explain_sql = "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT) $sql";
            my $explain_sth = $dbh->prepare($explain_sql);
            $explain_sth->execute(@lateral_params, @params, @limit_params);
            my @plan_lines;
            while ( my @row = $explain_sth->fetchrow_array ) {
                push @plan_lines, $row[0];
            }
            $explain_sth->finish;
            $logger->info("[EXPLAIN] Query: $sql");
            $logger->info("[EXPLAIN] Params: " . join(", ", @lateral_params, @params, @limit_params));
            foreach my $line (@plan_lines) {
                $logger->info("[EXPLAIN] $line");
            }
        };
        if ($@) {
            $logger->info("[EXPLAIN] Failed to run EXPLAIN ANALYZE: $@");
        }
    }

    return ( $archive_filtered_count, @ids );
}

# Run the prepared tank statement.
# Returns ($filtered_count, @tank_ids)
sub search_tanks_with_dbh ( $dbh, $where_sql, $params_in, $sortkey, $sortorder, $start, $keysperpage ) {

    my $logger = get_logger( "PgSearch Tank", "lanraragi" );
    my @params = @$params_in;

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

    # Build LIMIT/OFFSET clause
    my $limit_sql = "";
    my @limit_params = ();
    if ( defined $start && defined $keysperpage && $keysperpage > 0 ) {
        $limit_sql = "LIMIT ? OFFSET ?";
        push @limit_params, $keysperpage, $start;
    }

    # Single query with COUNT(*) OVER() to get filtered count and paginated results together.
    my $sql = "SELECT t.tankid, COUNT(*) OVER() as filtered_total FROM lrr_tank t $where_sql $order_sql $limit_sql";

    $logger->debug("Tank SQL: $sql");
    $logger->debug("Tank Params: " . join(", ", @params));
    $logger->debug("Tank LIMIT params: " . join(", ", @limit_params));

    my $select_start = time();
    my $sth = $dbh->prepare($sql);
    $sth->execute(@params, @limit_params);

    my @tank_ids;
    my $tank_filtered_count = 0;
    while ( my $row = $sth->fetchrow_hashref ) {
        $tank_filtered_count = $row->{filtered_total} unless $tank_filtered_count;
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
