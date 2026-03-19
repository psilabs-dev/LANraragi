package LANraragi::Utils::PsilabsDev::Database;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_dbh initialize BACKEND);

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
    } else {
        die "Unknown database backend: " . BACKEND;
    }
}

sub get_dbh { return $_get_dbh->(); }

sub initialize {
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
