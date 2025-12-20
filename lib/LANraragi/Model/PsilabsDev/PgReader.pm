package LANraragi::Model::PsilabsDev::PgReader;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;

use File::Basename;
use Mojo::JSON qw(encode_json);
use Data::Dumper;
use URI::Escape;

use LANraragi::Utils::Generic qw(is_image);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Archive qw(get_filelist);
use LANraragi::Utils::Redis   qw(redis_decode);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::PsilabsDev::PgPath;

# replaces LANraragi::Model::Reader::build_reader_JSON
# build_reader_JSON(mojo, id, forceReload)
# Opens the archive specified by its ID, and returns a json containing the page names.
sub build_reader_JSON ( $self, $id, $force ) {

    # Get the path from Postgres.
    # Filenames are stored as they are on the OS, so no decoding!
    my $dbh = get_postgresql_dbh();
    my $archive = LANraragi::Utils::PsilabsDev::PgPath::get_archive_path( $dbh, $id );

    # Parse archive to get its list of images
    my @images = get_filelist($archive, $id);

    $self->LRR_LOGGER->debug( "Files found in archive (encoding might be incorrect): \n " . Dumper @images );

    # Build a browser-compliant filepath array from @images
    my @images_browser;

    foreach my $imgpath (@images) {

        # Since we're using uri_escape_utf8 for escaping, we need to make sure the path is valid UTF8.
        # The good ole' redis_decode allows us to make sure of that.
        $imgpath = redis_decode($imgpath);

        # We need to sanitize the image's path, in case the folder contains illegal characters,
        # but uri_escape would also nuke the / needed for navigation. Let's solve this with a quick regex search&replace.
        # First, we encode all HTML characters...
        $imgpath = uri_escape_utf8($imgpath);

        # Then we bring the slashes back.
        $imgpath =~ s!%2F!/!g;

        # Bundle this path into an API call which will be used by the browser
        push @images_browser, $self->url_for("/api/archives/$id/page?path=$imgpath")->path_query;
    }

    # Update pagecount in Postgres
    eval {
        my $sth = $dbh->prepare('UPDATE lrr_archive SET pagecount = ? WHERE arcid = ?');
        $sth->execute(scalar @images, $id);
        $sth->finish;
    };

    if (my $error = $@) {
        my $logger = get_logger("PgReader", "lanraragi");
        $logger->error("Error updating pagecount for archive $id: $error");
        $dbh->disconnect();
        die $error;
    }

    $dbh->disconnect();

    return { pages => \@images_browser, };
}

1;
