package LANraragi::Utils::PsilabsDev::DatabaseUtils;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(
  get_archive get_archive_json get_archive_json_multi get_tags_string_with_dbh get_archive_summary_with_dbh
  set_tags set_tags_with_dbh set_title set_title_with_dbh set_summary set_summary_with_dbh
  set_isnew clear_new_all invalidate_cache clean_database clean_categories_and_tanks
  change_archive_id drop_database
);

use LANraragi::Model::Config;
use LANraragi::Utils::PsilabsDev::Database qw(BACKEND);
use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Utils::PsilabsDev::PgDatabase',
        redis    => 'LANraragi::Utils::Database',
    );

    # Adapters for _with_dbh functions that have no Redis equivalent.
    # Redis-side functions are self-managing; the $handle param is either
    # used directly (for get_tags_string) or ignored.
    if ( BACKEND eq 'redis' ) {
        require LANraragi::Utils::Redis;
        LANraragi::Utils::Redis->import('redis_decode');

        no strict 'refs';

        # Use the passed Redis handle directly for tag fetching
        *get_tags_string_with_dbh = sub {
            my ( $handle, $id ) = @_;
            my $tags = $handle->hget( $id, "tags" );
            return redis_decode($tags) // "";
        };

        # Build summary from get_archive (self-managing)
        *get_archive_summary_with_dbh = sub {
            my ( $handle, $id ) = @_;
            my %hash = LANraragi::Utils::Database::get_archive($id);
            return unless %hash;
            return {
                arcid    => $id,
                filename => $hash{file},
                title    => $hash{title} // "",
                tags     => $hash{tags}  // ""
            };
        };

        # Ignore handle, delegate to self-managing Redis functions
        *set_tags_with_dbh = sub {
            my ( $handle, $id, $newtags, $append ) = @_;
            LANraragi::Utils::Database::set_tags( $id, $newtags, $append );
        };

        *set_title_with_dbh = sub {
            my ( $handle, $id, $newtitle ) = @_;
            LANraragi::Utils::Database::set_title( $id, $newtitle );
        };

        *set_summary_with_dbh = sub {
            my ( $handle, $id, $summary ) = @_;
            LANraragi::Utils::Database::set_summary( $id, $summary );
        };

        # clear_new_all: Redis implementation (from upstream Controller::Api::Database)
        *clear_new_all = sub {
            my $redis        = LANraragi::Model::Config->get_redis;
            my $redis_search = LANraragi::Model::Config->get_redis_search;

            my @keys = $redis_search->smembers("LRR_NEW");
            foreach my $key (@keys) {
                $redis->hset( $key, "isnew", "false" );
            }

            $redis_search->del("LRR_NEW");
            $redis_search->quit();
            $redis->quit();
        };
    }
}

1;
