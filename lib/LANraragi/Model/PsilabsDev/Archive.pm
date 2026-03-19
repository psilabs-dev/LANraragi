package LANraragi::Model::PsilabsDev::Archive;

use strict;
use warnings;
use utf8;

use LANraragi::Model::Config;
use LANraragi::Utils::Path qw(create_path);
use LANraragi::Utils::PsilabsDev::Database qw(BACKEND);
use LANraragi::Utils::PsilabsDev::ProxyFactory qw(make_proxy);

BEGIN {
    make_proxy( __PACKAGE__,
        postgres => 'LANraragi::Model::PsilabsDev::PgArchive',
        redis    => 'LANraragi::Model::Archive',
    );

    # Adapters for functions that only exist on the Postgres side.
    # Redis equivalents are reimplemented from upstream controller logic.
    if ( BACKEND eq 'redis' ) {

        require LANraragi::Utils::Redis;
        LANraragi::Utils::Redis->import('redis_encode');

        no strict 'refs';

        # Handle-accepting data access (Shinobu, Minion)
        *get_stored_filename_with_handle = sub {
            my ( $handle, $id ) = @_;
            return undef unless $handle->exists($id);
            return create_path( $handle->hget( $id, "file" ) );
        };

        *update_stored_filename_with_handle = sub {
            my ( $handle, $id, $file, $name ) = @_;
            $handle->hset( $id, "file", $file );
            $handle->hset( $id, "name", redis_encode($name) );
            $handle->wait_all_responses;
        };

        *get_arcsize_with_handle = sub {
            my ( $handle, $id ) = @_;
            return $handle->hget( $id, "arcsize" );
        };

        *get_pagecount_with_handle = sub {
            my ( $handle, $id ) = @_;
            return $handle->hget( $id, "pagecount" );
        };

        *get_all_archive_ids_with_handle = sub {
            my ($handle) = @_;
            return $handle->keys('????????????????????????????????????????');
        };

        *get_all_thumbhashes_with_handle = sub {
            my ($handle) = @_;
            my @keys = $handle->keys('????????????????????????????????????????');
            my %hashes;
            foreach my $id (@keys) {
                my $thumbhash = $handle->hget( $id, "thumbhash" );
                $hashes{$id} = $thumbhash if $thumbhash;
            }
            return %hashes;
        };

        # Upstream: controller does $redis->hset($id, "progress", $page) inline.
        *update_progress = sub {
            my ( $id, $page, $force ) = @_;
            my $redis     = LANraragi::Model::Config->get_redis;
            my $redis_cfg = LANraragi::Model::Config->get_redis_config;
            my $time      = time();
            my $pagecount = $redis->hget( $id, "pagecount" );
            $redis->hset( $id, "progress",     $page );
            $redis->hset( $id, "lastreadtime", $time );
            $redis->quit();
            $redis_cfg->incr("LRR_TOTALPAGESTAT");
            $redis_cfg->quit();
            return { pagecount => $pagecount, lastreadtime => $time };
        };

        # Upstream: controller does $redis_search->smembers("LRR_UNTAGGED").
        *get_untagged_archives = sub {
            my $redis_search = LANraragi::Model::Config->get_redis_search;
            my @untagged     = $redis_search->smembers("LRR_UNTAGGED");
            $redis_search->quit();
            return @untagged;
        };

        # Upstream: controller does $redis->exists($id).
        *archive_exists = sub {
            my ($id) = @_;
            return 0 if $id eq "";
            my $redis  = LANraragi::Model::Config->get_redis;
            my $exists = $redis->exists($id) ? 1 : 0;
            $redis->quit();
            return $exists;
        };

        # Upstream: controller does $redis->randomkey() in a loop.
        *get_random_archive = sub {
            my $redis = LANraragi::Model::Config->get_redis;
            my $arcid;
            for ( 1 .. 100 ) {
                my $key = $redis->randomkey();
                if (   defined($key)
                    && length($key) == 40
                    && $redis->type($key) eq "hash"
                    && $redis->hexists( $key, "file" ) )
                {
                    my $file = LANraragi::Utils::Path::create_path( $redis->hget( $key, "file" ) );
                    if ( defined($file) && -e $file ) {
                        $arcid = $key;
                        last;
                    }
                }
            }
            $redis->quit();
            return $arcid;
        };
    }
}

1;
