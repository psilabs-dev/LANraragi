package LANraragi::Utils::PsilabsDev::Postgres;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_postgresql_dbh initialize_database);

use DBD::Pg;
use DBI;
use LANraragi::Utils::Logging  qw(get_logger);

# Get the PostgreSQL database connection.
sub get_postgresql_dbh {

    # required variables.
    # TODO: this needs to be populated but for now we can just go with this.
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

sub initialize_database {
    my $dbh     = shift;
    my $logger  = get_logger("Postgres Utils", "lanraragi");
    my $rv;
    my $sql;

    $logger->info("Initializing PostgreSQL database...");

    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_archive (
    arcid           VARCHAR(255) PRIMARY KEY,
    filename        VARCHAR(255) NOT NULL,
    extension       VARCHAR(255),
    isnew           BOOLEAN NOT NULL,
    lastreadtime    INTEGER NOT NULL,
    pagecount       INTEGER NOT NULL,
    progress        INTEGER NOT NULL,
    title           VARCHAR(255) NOT NULL,
    summary         TEXT,
    thumbhash       VARCHAR(255),
    arcsize         BIGINT,
    search_tsv      tsvector
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_archive table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_archive");

    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_category (
    catid           VARCHAR(255) PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    pinned          BOOLEAN NOT NULL,
    search          VARCHAR(255)
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_category table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_category");
    
    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_tank (
    tankid          VARCHAR(255) PRIMARY KEY,
    name            VARCHAR(255) NOT NULL,
    summary         TEXT,
    tags            TEXT
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_tank table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_tank");

    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_tag (
    tagid           INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    namespace       VARCHAR(255) NOT NULL DEFAULT '',
    value           VARCHAR(255) NOT NULL,
    UNIQUE (namespace, value)
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_tag table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_tag");

    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_category_to_archive_map (
    catid           VARCHAR(255) NOT NULL,
    arcid           VARCHAR(255) NOT NULL,
    update_date     DATE,
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    FOREIGN KEY (catid) REFERENCES lrr_category (catid)
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_category_to_archive_map table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_category_to_archive_map");

    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_archive_to_tag_map (
    arcid           VARCHAR(255) NOT NULL,
    tagid           INTEGER NOT NULL,
    update_date     DATE,
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    FOREIGN KEY (tagid) REFERENCES lrr_tag (tagid)
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_archive_to_tag_map table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_archive_to_tag_map");

    $sql = <<'SQL';
CREATE TABLE IF NOT EXISTS lrr_tank_to_archive_map (
    tankid          VARCHAR(255) NOT NULL,
    arcid           VARCHAR(255) NOT NULL,
    position        INTEGER NOT NULL,
    update_date     DATE,
    FOREIGN KEY (arcid) REFERENCES lrr_archive (arcid),
    FOREIGN KEY (tankid) REFERENCES lrr_tank (tankid)
)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create lrr_tank_to_archive_map table: $errorcode - $errorstr";
    }
    $logger->info("Created table: lrr_tank_to_archive_map");

    $sql = <<'SQL';
CREATE EXTENSION IF NOT EXISTS pg_trgm
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create pg_trgm extension: $errorcode - $errorstr";
    }
    $logger->info("Created extension: pg_trgm");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_title_trgm ON lrr_archive USING gin (title gin_trgm_ops)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_title_trgm index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_title_trgm");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_search_tsv ON lrr_archive USING gin (search_tsv)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_search_tsv index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_search_tsv");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_tag_value_trgm ON lrr_tag USING gin (value gin_trgm_ops)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_tag_value_trgm index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_tag_value_trgm");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_arcid ON lrr_archive_to_tag_map (arcid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_to_tag_arcid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_to_tag_arcid");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_tagid ON lrr_archive_to_tag_map (tagid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_to_tag_tagid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_to_tag_tagid");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_isnew ON lrr_archive (isnew)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_isnew index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_isnew");

    # P7: Category to archive mapping indexes
    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_category_to_archive_catid ON lrr_category_to_archive_map (catid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_category_to_archive_catid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_category_to_archive_catid");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_category_to_archive_arcid ON lrr_category_to_archive_map (arcid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_category_to_archive_arcid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_category_to_archive_arcid");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_category_to_archive_catid_arcid ON lrr_category_to_archive_map (catid, arcid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_category_to_archive_catid_arcid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_category_to_archive_catid_arcid");

    # P7: Tank to archive mapping indexes
    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_tank_to_archive_tankid ON lrr_tank_to_archive_map (tankid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_tank_to_archive_tankid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_tank_to_archive_tankid");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_tank_to_archive_arcid ON lrr_tank_to_archive_map (arcid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_tank_to_archive_arcid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_tank_to_archive_arcid");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_tank_to_archive_tankid_position ON lrr_tank_to_archive_map (tankid, position)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_tank_to_archive_tankid_position index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_tank_to_archive_tankid_position");

    # P8: Tag namespace trigram index
    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_tag_namespace_trgm ON lrr_tag USING gin (namespace gin_trgm_ops)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_tag_namespace_trgm index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_tag_namespace_trgm");

    # P9: Sort optimization index
    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_lastreadtime ON lrr_archive (lastreadtime DESC)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_lastreadtime index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_lastreadtime");

    # P14: Filter optimization indexes
    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_pagecount ON lrr_archive (pagecount)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_pagecount index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_pagecount");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_progress ON lrr_archive (progress)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_progress index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_progress");

    # P2-Lite: Composite indexes for EXISTS subquery optimization
    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_tag_namespace_value ON lrr_tag (namespace, value)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_tag_namespace_value index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_tag_namespace_value");

    $sql = <<'SQL';
CREATE INDEX IF NOT EXISTS idx_lrr_archive_to_tag_arcid_tagid ON lrr_archive_to_tag_map (arcid, tagid)
SQL
    $rv = $dbh->do($sql);
    unless ( defined $rv ) {
        my $errorcode   = $dbh->err // '';
        my $errorstr    = $dbh->errstr // '';
        die "Failed to create idx_lrr_archive_to_tag_arcid_tagid index: $errorcode - $errorstr";
    }
    $logger->info("Created index: idx_lrr_archive_to_tag_arcid_tagid");

    $logger->info("PostgreSQL database initialized successfully");
}

1;