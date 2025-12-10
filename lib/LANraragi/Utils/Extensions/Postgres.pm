package LANraragi::Utils::Extensions::Postgres;

use strict;
use warnings;
use utf8;

use DBD::Pg;
use DBI;
use LANraragi::Utils::Logging  qw(get_logger);

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

        . 'isnew BOOLEAN NOT NULL,'
        . 'lastreadtime INTEGER NOT NULL,'
        . 'pagecount INTEGER NOT NULL,'
        . 'progress INTEGER NOT NULL,'

        . 'title VARCHAR(255) NOT NULL,'
        . 'summary TEXT'

        . ')'
    );
    # With RaiseError => 1, any error would have thrown already.
    # Keep a defensive check for completeness.
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_archive table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_archive");

    # category metadata
    # TODO: category ID might be also made stricter since it's a known structure.
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_category ('
        . 'catid VARCHAR(255) PRIMARY KEY,'
        . 'name VARCHAR(255) NOT NULL,'
        . 'pinned BOOLEAN NOT NULL,'
        . 'search VARCHAR(255)'
        . ')'
    );
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_category table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_category");

    # tank metadata
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_tank ('
        . 'tankid VARCHAR(255) PRIMARY KEY,'
        . 'name VARCHAR(255) NOT NULL,'
        . 'summary TEXT,'
        . 'tags TEXT'
        . ')'
    );
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_tank table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_tank");

    # archive to category relation
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_category_to_archive_map ('
        . 'catid VARCHAR(255) NOT NULL,'
        . 'arcid VARCHAR(255) NOT NULL,'
        . 'update_date DATE,'
        . 'FOREIGN KEY (arcid) REFERENCES lrr_archive(arcid),'
        . 'FOREIGN KEY (catid) REFERENCES lrr_category(catid)'
        . ')'
    );
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_category_to_archive_map table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_category_to_archive_map");

    # tag metadata
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_tag ('
        . 'tagid INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,'
        . 'namespace VARCHAR(255) NOT NULL DEFAULT \'\','
        . 'value VARCHAR(255) NOT NULL,'
        . 'UNIQUE(namespace, value)'
        . ')'
    );
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_tag table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_tag");

    # archive to tag relation
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_archive_to_tag_map ('
        . 'arcid VARCHAR(255) NOT NULL,'
        . 'tagid INTEGER NOT NULL,'
        . 'update_date DATE,'
        . 'FOREIGN KEY (arcid) REFERENCES lrr_archive(arcid),'
        . 'FOREIGN KEY (tagid) REFERENCES lrr_tag(tagid),'
        . 'UNIQUE(arcid, tagid)'
        . ')'
    );
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_archive_to_tag_map table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_archive_to_tag_map");

    # archive to tank relation
    # TODO: tank order probably matters, so we should think about this more
    # at the same time, writes are much less frequent than reads.
    $rv = $dbh->do(
        'CREATE TABLE IF NOT EXISTS lrr_tank_to_archive_map ('
        . 'tankid VARCHAR(255) NOT NULL,'
        . 'arcid VARCHAR(255) NOT NULL,'
        . 'position INTEGER NOT NULL,'
        . 'update_date DATE,'
        . 'FOREIGN KEY (arcid) REFERENCES lrr_archive(arcid),'
        . 'FOREIGN KEY (tankid) REFERENCES lrr_tank(tankid),'
        . 'UNIQUE(tankid, arcid),'
        . 'UNIQUE(tankid, position)'
        . ')'
    );
    unless ( defined $rv ) {
        my $errorcode = $dbh->err // '';
        my $errorstr  = $dbh->errstr // '';
        $dbh->disconnect();
        die "Failed to create lrr_tank_to_archive_map table (code $errorcode): $errorstr";
    }
    $logger->info("Created table: lrr_tank_to_archive_map");

    # Close handle
    $dbh->disconnect();
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