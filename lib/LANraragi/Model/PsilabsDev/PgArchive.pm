package LANraragi::Model::PsilabsDev::PgArchive;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_random_archive_id get_archive_filename);

use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Logging qw(get_logger);

# replaces: Redis randomkey() + type check for archive selection
# get_random_archive_id()
#   Returns a random archive ID from the database.
#   Returns empty string if no archives exist.
sub get_random_archive_id {
    my $logger = get_logger("PgArchive", "lanraragi");
    my $dbh = get_postgresql_dbh();

    # Get a random archive ID using PostgreSQL's RANDOM() function
    my $sql = <<'SQL';
        SELECT arcid
        FROM lrr_archive
        ORDER BY RANDOM()
        LIMIT 1
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute();

    my $arcid = "";
    if (my $row = $sth->fetchrow_hashref) {
        $arcid = $row->{arcid};
        $logger->debug("Found random archive: $arcid");
    } else {
        $logger->debug("No archives found in database");
    }

    $dbh->disconnect();

    return $arcid;
}

# replaces: $redis->hget($id, "file")
# get_archive_filename($arcid)
#   Returns the filename for the given archive ID.
#   Returns empty string if archive doesn't exist.
sub get_archive_filename {
    my ($arcid) = @_;
    my $logger = get_logger("PgArchive", "lanraragi");
    my $dbh = get_postgresql_dbh();

    my $sql = <<'SQL';
        SELECT filename
        FROM lrr_archive
        WHERE arcid = ?
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute($arcid);

    my $filename = "";
    if (my $row = $sth->fetchrow_hashref) {
        $filename = $row->{filename};
        $logger->debug("Found filename for $arcid: $filename");
    } else {
        $logger->debug("Archive $arcid not found in database");
    }

    $dbh->disconnect();

    return $filename;
}

1;
