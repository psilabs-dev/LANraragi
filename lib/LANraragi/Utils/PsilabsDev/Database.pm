package LANraragi::Utils::PsilabsDev::Database;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_dbh get_handle close_handle begin_transaction commit_transaction rollback_transaction initialize BACKEND);

use constant BACKEND => ( $ENV{LRR_DATABASE_BACKEND} // 'postgres' );

# Conditionally load only the selected backend — its dependencies
# (DBD::Pg, DBD::SQLite, etc.) are only pulled in here.
my $_get_dbh;
my $_initialize;

BEGIN {
    if ( BACKEND eq 'postgres' ) {
        require LANraragi::Utils::PsilabsDev::Postgres;
        $_get_dbh    = \&LANraragi::Utils::PsilabsDev::Postgres::get_postgresql_dbh;
        $_initialize = \&LANraragi::Utils::PsilabsDev::Postgres::initialize_database;
    } elsif ( BACKEND eq 'redis' ) {
        $_get_dbh    = undef;
        $_initialize = sub { };
    } else {
        die "Unknown database backend: " . BACKEND;
    }
}

# Returns a DBI database handle (Postgres/SQLite only).
# Dies on Redis — callers should use get_handle() instead.
sub get_dbh {
    die "get_dbh() is not available for backend '" . BACKEND . "'; use get_handle() instead"
        unless $_get_dbh;
    return $_get_dbh->();
}

# Returns a backend-appropriate handle ($dbh or $redis).
# Controllers use this at the customs border.
sub get_handle {
    if ( BACKEND eq 'postgres' ) { return get_dbh(); }
    elsif ( BACKEND eq 'redis' ) { return LANraragi::Model::Config->get_redis; }
}

# Closes a handle returned by get_handle.
sub close_handle {
    my ($handle) = @_;
    if ( BACKEND eq 'postgres' ) { $handle->disconnect(); }
    elsif ( BACKEND eq 'redis' ) { $handle->quit(); }
}

# Transaction helpers — no-ops for Redis.
sub begin_transaction {
    my ($handle) = @_;
    $handle->begin_work if BACKEND eq 'postgres';
}

sub commit_transaction {
    my ($handle) = @_;
    $handle->commit if BACKEND eq 'postgres';
}

sub rollback_transaction {
    my ($handle) = @_;
    eval { $handle->rollback } if BACKEND eq 'postgres';
}

sub initialize {
    if ( BACKEND eq 'redis' ) {
        $_initialize->();
        return;
    }
    my $dbh = get_dbh();
    eval {
        $_initialize->($dbh);
        $dbh->disconnect();
    } or do {
        my $error = $@;
        $dbh->disconnect();
        die $error;
    };
}

1;
