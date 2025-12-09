package LANraragi::Model::Extensions::SqliteSearch;

use feature qw(signatures);
no warnings 'experimental::signatures';

use strict;
use warnings;
use utf8;

# Search module for an instance using Sqlite.

# The only exported method of this module.
sub do_search(
    $filter, $category_id, $start, $sortkey,
    $sortorder, $newonly, $untaggedonly, $grouptanks
) {
    my $redis   = LANraragi::Model::Config->get_redis_search;
    my $logger  = get_logger("Sqlite Search Engine", "lanraragi");
    my $dbh; # TODO: get the database handler.
}

1;