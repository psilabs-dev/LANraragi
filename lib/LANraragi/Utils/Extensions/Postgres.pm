package LANraragi::Utils::Extensions::Postgres;

use strict;
use warnings;
use utf8;

use DBD::Pg;
use DBI;

# All utilities related to establishing PostgreSQL clients, getting clients, common helper methods, etc.

# Get the postgresql database connection.
sub get_dbh {

    # required variables.
    # TODO: this needs to be populated.
    my $dbname = $ENV{LRR_POSTGRES_DB}          // 'postgres';
    my $host = $ENV{LRR_POSTGRES_HOST}          // 'postgres';
    my $port = $ENV{LRR_POSTGRES_PORT}          // 5432;
    # my $options = ''; # TODO: figure out if options is needed.
    my $username = $ENV{LRR_POSTGRES_USER}      // 'postgres';
    my $password = $ENV{LRR_POSTGRES_PASSWORD}  // 'postgres';

    my $dbh = DBI->connect(
        "dbi:Pg:dbname=$dbname;host=$host;port=$port",
        $username,
        $password,
        {
            AutoCommit => 1,
            RaiseError => 1,
            PrintError => 0
        }
    );

    return $dbh;
}

# Initialize database with archive, category and tank metadata,
# as well as mappings between the three.
sub initialize_database {

    my $self    = shift;
    my $logger  = get_logger( "Postgres", "lanraragi" );
    my $dbh     = get_dbh();
    my $rv;

    # archive metadata
    # TODO: the arcid might be reduced since it's a known hash structure.
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_archive ('
        . 'arcid VARCHAR(255) PRIMARY KEY,'

        . 'filename VARCHAR(255) NOT NULL,'
        . 'extension VARCHAR(255),'

        . 'isnew BOOLEAN,'
        . 'lastreadtime INTEGER,'
        . 'pagecount INTEGER,'
        . 'progress INTEGER,'

        . 'title VARCHAR(255),'
        . 'tags TEXT,'
        . 'summary TEXT,'

        . ')'
    );
    if ( defined $rv ) {
        my $errorcode = $dbh->err;
        die "Failed to create lrr_archive table (code $errorcode): $@";
    }
    $logger->info("Created table: lrr_archive");

    # category metadata
    # TODO: category ID might be also made stricter since it's a known structure.
    $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_category ('
        . 'catid VARCHAR(255) PRIMARY KEY,'
        . 'name VARCHAR(255) NOT NULL,'
        . 'pinned BOOLEAN,'
        . 'search VARCHAR(255),'
        . ')'
    );
    if ( defined $rv ) {
        my $errorcode = $dbh->err;
        die "Failed to create lrr_category table (code $errorcode): $@";
    }
    $logger->info("Created table: lrr_category");

    # tank metadata
    # TODO: finish the schema.
    $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_tank ('
        . 'tankid VARCHAR(255) PRIMARY KEY,'
        . ')'
    );
    if ( defined $rv ) {
        my $errorcode = $dbh->err;
        die "Failed to create lrr_tank table (code $errorcode): $@";
    }
    $logger->info("Created table: lrr_tank");

    # archive to category relation
    # TODO: does arc-to-category order matter/is used anywhere?
    $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_category_to_archive_map ('
        . 'catid VARCHAR(255),'
        . 'arcid VARCHAR(255),'
        . 'update_date DATE,'
        . 'FOREIGN KEY arcid REFERENCES lrr_archive(arcid),'
        . 'FOREIGN KEY catid REFERENCES lrr_category(catid)'
        . ')'
    );
    if ( defined $rv ) {
        my $errorcode = $dbh->err;
        die "Failed to create lrr_category_to_archive_map table (code $errorcode): $@";
    }
    $logger->info("Created table: lrr_category_to_archive_map");

    # archive to tank relation
    # TODO: tank order probably matters, so we should think about this more
    # at the same time, writes are much less frequent than reads.
    $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_tank_to_archive_map ('
        . 'tankid VARCHAR(255),'
        . 'arcid VARCHAR(255),'
        . 'order INTEGER,'
        . 'update_date DATE,'
        . 'FOREIGN KEY arcid REFERENCES lrr_archive(arcid),'
        . 'FOREIGN KEY tankid REFERENCES lrr_tank(tankid)'
        . ')'
    );
    if ( defined $rv ) {
        my $errorcode = $dbh->err;
        die "Failed to create lrr_tank_to_archive_map table (code $errorcode): $@";
    }
    $logger->info("Created table: lrr_tank_to_archive_map");

}

# Generic transactional scope.
sub transactional {
    my ( $dbh, $func ) = @_;
    my $result;

    $dbh->begin_work();
    eval {
        $result = $func->();
    };
    $dbh->commit();

    # TODO: error handling, show error code and message from database if exists.
    return $result;
}

1;