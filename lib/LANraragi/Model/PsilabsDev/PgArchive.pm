package LANraragi::Model::PsilabsDev::PgArchive;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;

use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::Path qw(create_path);

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

1;
