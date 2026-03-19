package LANraragi::Model::PsilabsDev::Upload;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(
  add_timestamp_tag add_pagecount add_arcsize
  add_timestamp_tag_with_dbh add_pagecount_with_dbh add_arcsize_with_dbh
  add_archive_to_db handle_incoming_file
);

use LANraragi::Model::Config;
use LANraragi::Utils::PsilabsDev::Database qw(BACKEND);
use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgUpload',
        redis    => 'LANraragi::Model::Upload',
    );

    no strict 'refs';
    if ( BACKEND eq 'postgres' ) {
        *add_archive_to_db = \&LANraragi::Model::PsilabsDev::PgUpload::add_archive_to_postgres;
    } elsif ( BACKEND eq 'redis' ) {
        # Redis add_archive_to_redis takes ($id, $file, $redis, $redis_search) — 4 args.
        # Callers pass ($id, $file, $handle) — 3 args. Adapter gets the search handle.
        *add_archive_to_db = sub {
            my ( $id, $file, $redis ) = @_;
            my $redis_search = LANraragi::Model::Config->get_redis_search;
            LANraragi::Utils::Database::add_archive_to_redis( $id, $file, $redis, $redis_search );
            $redis_search->quit();
        };

        # _with_dbh adapters: Redis equivalents take ($redis, $id) — same as ($handle, $id).
        *add_timestamp_tag_with_dbh = sub {
            my ( $handle, $id ) = @_;
            LANraragi::Utils::Database::add_timestamp_tag( $handle, $id );
        };
        *add_pagecount_with_dbh = sub {
            my ( $handle, $id ) = @_;
            LANraragi::Utils::Database::add_pagecount( $handle, $id );
        };
        *add_arcsize_with_dbh = sub {
            my ( $handle, $id ) = @_;
            LANraragi::Utils::Database::add_arcsize( $handle, $id );
        };

        # Self-managing adapters: PgUpload takes ($id), Redis takes ($redis, $id).
        *add_timestamp_tag = sub {
            my ($id) = @_;
            my $redis = LANraragi::Model::Config->get_redis;
            LANraragi::Utils::Database::add_timestamp_tag( $redis, $id );
            $redis->quit();
        };
        *add_pagecount = sub {
            my ($id) = @_;
            my $redis = LANraragi::Model::Config->get_redis;
            LANraragi::Utils::Database::add_pagecount( $redis, $id );
            $redis->quit();
        };
        *add_arcsize = sub {
            my ($id) = @_;
            my $redis = LANraragi::Model::Config->get_redis;
            LANraragi::Utils::Database::add_arcsize( $redis, $id );
            $redis->quit();
        };
    }
}

1;
