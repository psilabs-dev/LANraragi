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

1;
