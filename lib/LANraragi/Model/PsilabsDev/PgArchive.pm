package LANraragi::Model::PsilabsDev::PgArchive;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;

use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Generic qw(render_api_response);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Path qw(create_path);
use LANraragi::Utils::Archive qw(extract_single_file);
use LANraragi::Utils::PageCache qw(fetch put);
use LANraragi::Utils::PsilabsDev::PgPath;
use LANraragi::Model::Config;
use LANraragi::Model::Reader;

use File::Basename;

# replaces LANraragi::Model::Archive::generate_archive_list
# Generates an array of all the archive JSONs in the database that have existing files.
sub generate_archive_list {

    my $logger = get_logger( "PgArchive", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    my @archives;

    eval {
        # Query all archives with their tags
        my $sql = q{
            SELECT
                a.arcid,
                a.filename,
                a.title,
                a.summary,
                a.isnew,
                a.progress,
                a.pagecount,
                a.lastreadtime,
                a.arcsize,
                a.extension,
                COALESCE(
                    string_agg(
                        CASE
                            WHEN t.namespace = '' THEN t.value
                            ELSE t.namespace || ':' || t.value
                        END,
                        ', '
                    ),
                    ''
                ) as tags
            FROM lrr_archive a
            LEFT JOIN lrr_archive_to_tag_map atm ON a.arcid = atm.arcid
            LEFT JOIN lrr_tag t ON atm.tagid = t.tagid
            GROUP BY a.arcid, a.filename, a.title, a.summary, a.isnew,
                     a.progress, a.pagecount, a.lastreadtime, a.arcsize, a.extension
            ORDER BY a.title
        };

        my $sth = $dbh->prepare($sql);
        $sth->execute();

        while (my $row = $sth->fetchrow_hashref) {
            # Check if file exists on filesystem (matches Redis implementation in Database.pm:239-240)
            my $file = create_path($row->{filename});
            next unless ( defined($file) && -e $file );

            # Handle whitespace-only title (matches Redis implementation in Database.pm:246-248)
            my $title = $row->{title};
            if ( !defined($title) || $title =~ /^\s*$/ ) {
                $title = $row->{filename};
            }

            my $arcdata = {
                arcid        => $row->{arcid},
                title        => $title,
                filename     => $row->{filename},
                tags         => $row->{tags} // '',
                summary      => $row->{summary} // '',
                isnew        => $row->{isnew} ? 'true' : 'false',
                extension    => $row->{extension} // '',
                progress     => $row->{progress} ? int($row->{progress}) : 0,
                pagecount    => $row->{pagecount} ? int($row->{pagecount}) : 0,
                lastreadtime => $row->{lastreadtime} ? int($row->{lastreadtime}) : 0,
                size         => $row->{arcsize} ? int($row->{arcsize}) : 0
            };

            push @archives, $arcdata;
        }

        $sth->finish;
    };

    if (my $error = $@) {
        $logger->error("Error generating archive list: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    return @archives;
}

# replaces serve_untagged_archivelist logic from LANraragi::Controller::Api::Archive
# Returns a list of archive IDs that have no "meaningful" tags.
# Archives are considered untagged if they have NO tags at all, OR only have tags
# from "basic" namespaces that don't count as tagged: artist, parody, series,
# language, event, group, date_added, timestamp, source
sub get_untagged_archives {

    my $logger = get_logger( "PgArchive", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    my @untagged;

    eval {
        # Query archives that either have no tags, or only have tags from excluded namespaces
        # This matches the Redis logic in LANraragi::Model::Stats.pm line 149
        my $sql = q{
            SELECT a.arcid
            FROM lrr_archive a
            WHERE NOT EXISTS (
                SELECT 1
                FROM lrr_archive_to_tag_map atm
                INNER JOIN lrr_tag t ON atm.tagid = t.tagid
                WHERE atm.arcid = a.arcid
                AND t.namespace NOT IN ('artist', 'parody', 'series', 'language', 'event', 'group', 'date_added', 'timestamp', 'source')
            )
            ORDER BY a.arcid
        };

        my $sth = $dbh->prepare($sql);
        $sth->execute();

        while (my $row = $sth->fetchrow_hashref) {
            push @untagged, $row->{arcid};
        }

        $sth->finish;
    };

    if (my $error = $@) {
        $logger->error("Error retrieving untagged archives: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    return @untagged;
}

# replaces LANraragi::Controller::Index::random_archive logic
# Returns a random archive ID from the database that has an existing file on disk.
# Returns undef if no archives exist or none have valid files.
sub get_random_archive {

    my $logger = get_logger( "PgArchive", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    my $arcid;

    eval {
        # Get a random archive ID using Postgres ORDER BY RANDOM()
        # This is efficient enough for typical use cases
        my $sql = q{
            SELECT arcid, filename
            FROM lrr_archive
            ORDER BY RANDOM()
            LIMIT 1
        };

        my $sth = $dbh->prepare($sql);
        $sth->execute();

        while (my $row = $sth->fetchrow_hashref) {
            # Verify the file exists on disk before returning
            my $file = create_path($row->{filename});
            if ( defined($file) && -e $file ) {
                $arcid = $row->{arcid};
                last;
            }
            # If file doesn't exist, we could try again, but for simplicity
            # we return undef. The controller can handle this.
        }

        $sth->finish;
    };

    if (my $error = $@) {
        $logger->error("Error getting random archive: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    return $arcid;
}

# replaces LANraragi::Model::Archive::generate_page_thumbnails
sub generate_page_thumbnails {

    my ( $self, $id ) = @_;

    my $force = $self->req->param('force');
    $force = ( $force && $force eq "true" ) || "0";    # Prevent undef warnings by checking the variable first

    my $logger   = get_logger( "PgArchive", "lanraragi" );
    my $thumbdir = LANraragi::Model::Config->get_thumbdir;
    my $use_hq   = LANraragi::Model::Config->get_hqthumbpages;
    my $use_jxl  = LANraragi::Model::Config->get_jxlthumbpages;
    my $format   = $use_jxl ? 'jxl' : 'jpg';

    # Get the number of pages in the archive from Postgres
    my $dbh = get_postgresql_dbh();
    my $pages;

    eval {
        my $sql = q{SELECT pagecount FROM lrr_archive WHERE arcid = ?};
        my $sth = $dbh->prepare($sql);
        $sth->execute($id);
        my $row = $sth->fetchrow_hashref;
        $pages = $row->{pagecount} if $row;
        $sth->finish;
    };

    if (my $error = $@) {
        $logger->error("Error retrieving pagecount for archive $id: $error");
        $dbh->disconnect();
        LANraragi::Utils::Generic::render_api_response( $self, "generate_page_thumbnails", $error );
        return;
    }

    unless ($pages) {
        $dbh->disconnect();
        LANraragi::Utils::Generic::render_api_response( $self, "generate_page_thumbnails", "Archive has no pagecount." );
        return;
    }

    my $subfolder = substr( $id, 0, 2 );
    my $thumbname = "$thumbdir/$subfolder/$id.$format";

    my $should_queue_job = 0;

    for ( my $page = 1; $page <= $pages; $page++ ) {
        my $thumbname = "$thumbdir/$subfolder/$id/$page.$format";

        unless ( $force == 0 && -e $thumbname ) {
            $logger->debug("Thumbnail for page $page doesn't exist (path: $thumbname or force=$force), queueing job.");
            $should_queue_job = 1;
            last;
        }
    }

    # Done with Postgres
    $dbh->disconnect();

    if ($should_queue_job) {

        # Use Redis for ephemeral thumbjob tracking (caching operation)
        my $redis = LANraragi::Model::Config->get_redis;

        # Check if a job is already queued for this archive
        if ( $redis->hexists( $id, "thumbjob" ) ) {

            my $job_id = $redis->hget( $id, "thumbjob" );

            # If the job is pending or running, don't queue a new job and just return this one
            my $job_state = $self->minion->job($job_id)->info->{state};
            if ( $job_state eq "active" || $job_state eq "inactive" ) {
                $self->render(
                    json => {
                        operation => "generate_page_thumbnails",
                        success   => 1,
                        job       => $job_id
                    },
                    status => 202    # 202 Accepted
                );
                $redis->quit;
                return;
            }
        }

        # Queue a minion job to generate the thumbnails. Clients can check on its progress through the job ID.
        my $job_id = $self->minion->enqueue( page_thumbnails => [ $id, $force ] => { priority => 0, attempts => 3 } );

        # Save job in Redis so we can check on it if this endpoint is called again
        $redis->hset( $id, "thumbjob", $job_id );
        $self->render(
            json => {
                operation => "generate_page_thumbnails",
                success   => 1,
                job       => $job_id
            },
            status => 202    # 202 Accepted
        );
        $redis->quit;
    } else {
        $self->render(
            json => {
                operation => "generate_page_thumbnails",
                success   => 1,
                message   => "No job queued, all thumbnails already exist."
            },
            status => 200    # 200 OK
        );
    }
}

# replaces LANraragi::Controller::Api::Archive::update_progress (partial - the Redis metadata operations)
# Updates the reading progress for an archive.
# Returns a hashref with pagecount and lastreadtime values on success, or dies on error.
sub update_progress {
    my ($id, $page, $force) = @_;

    my $logger = get_logger("PgArchive", "lanraragi");
    my $dbh = get_postgresql_dbh();

    my $time = time();
    my $pagecount;

    eval {
        # Get the current pagecount for validation
        my $sth = $dbh->prepare('SELECT pagecount FROM lrr_archive WHERE arcid = ?');
        $sth->execute($id);
        my $row = $sth->fetchrow_hashref;
        $sth->finish;

        unless ($row) {
            die "Archive with ID $id not found";
        }

        $pagecount = $row->{pagecount};

        # Update progress and lastreadtime
        my $update_sth = $dbh->prepare('UPDATE lrr_archive SET progress = ?, lastreadtime = ? WHERE arcid = ?');
        $update_sth->execute($page, $time, $id);
        $update_sth->finish;

        $logger->debug("Updated progress for archive $id to page $page");
    };

    if (my $error = $@) {
        $logger->error("Error updating progress for archive $id: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    # Increment total pages read counter in Redis (configuration database)
    # Configuration exception: LRR_TOTALPAGESTAT remains in Redis Database 2
    my $redis = LANraragi::Model::Config->get_redis_config;
    $redis->incr("LRR_TOTALPAGESTAT");
    $redis->quit();

    # Return pagecount and lastreadtime for the caller
    return {
        pagecount    => $pagecount,
        lastreadtime => $time
    };
}

# replaces LANraragi::Model::Archive::get_page_data
sub get_page_data ($id, $path) {
    my $cachekey = "page/$id/$path";
    my $content = fetch($cachekey);
    if ( !defined($content) ) {
        # Extract the file from the parent archive if it doesn't exist
        my $dbh = get_postgresql_dbh();
        my $archive = LANraragi::Utils::PsilabsDev::PgPath::get_archive_path( $dbh, $id );
        $dbh->disconnect();
        $content = extract_single_file($archive, $path);
        put($cachekey, $content);
    }
    return $content;
}

# replaces LANraragi::Model::Archive::serve_page
sub serve_page {
    my ( $self, $id, $path ) = @_;

    my $logger = get_logger( "File Serving", "lanraragi" );

    $logger->debug("Page /$id/$path was requested");

    # Apply resizing transformation if set in Settings
    if ( LANraragi::Model::Config->enable_resize ) {

        # Store resized files in a subfolder of the ID's temp folder, keyed by quality
        my $threshold    = LANraragi::Model::Config->get_threshold;
        my $quality      = LANraragi::Model::Config->get_readquality;

        my $cachekey = "resize_page/$id/$path/$threshold/$quality";
        my $content = fetch($cachekey);
        if ( !defined($content)) {
            $content = LANraragi::Model::Reader::resize_image(get_page_data($id, $path), $quality, $threshold);
            put($cachekey, $content);
        }

        # LANraragi::Model::Reader::resize_image always converts the image to jpg
        $self->render_file(
            data                => $content,
            content_disposition => "inline",
            format              => "jpg"
        );
    } else {

     # Get the file extension to report content-type properly
        my ( $n, $p, $file_ext ) = fileparse( $path, qr/\.[^.]*/ );
        my $content = get_page_data($id, $path);
        $logger->debug("Data size:".length($content));
        # Serve extracted file directly
        $self->render_file(
            data                => $content,
            content_disposition => "inline",
            format              => substr( $file_ext, 1 )
        );
    }
}

1;
