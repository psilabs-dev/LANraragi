package LANraragi::Utils::PsilabsDev::PgArchive;

use v5.36;
use experimental 'try';

use strict;
use warnings;
use utf8;

use File::Path qw(make_path remove_tree);

use Exporter 'import';
our @EXPORT_OK = qw(extract_thumbnail extract_thumbnail_with_dbh delete_archive);

use LANraragi::Model::Config;
use LANraragi::Utils::Logging    qw(get_logger);
use LANraragi::Utils::Generic    qw(shasum_str);
use LANraragi::Utils::Archive    qw(get_filelist extract_single_file generate_thumbnail);
use LANraragi::Utils::Path       qw(unlink_path);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::PsilabsDev::PgPath qw(get_archive_path);

# replaces LANraragi::Model::Archive::delete_archive
# Deletes the archive with the given id from Postgres, and the matching archive file/thumbnail.
sub delete_archive ($id) {

    my $logger = get_logger( "Archive", "lanraragi" );
    my $dbh = get_postgresql_dbh();

    my $filename;  # Declare outside transaction

    $dbh->begin_work;

    eval {
        # Get the filename INSIDE transaction for consistency
        $filename = get_archive_path( $dbh, $id );

        # Delete from tank-to-archive mappings
        my $tank_sql = 'DELETE FROM lrr_tank_to_archive_map WHERE arcid = ?';
        my $tank_sth = $dbh->prepare($tank_sql);
        $tank_sth->execute($id);
        $tank_sth->finish;

        # Delete from category-to-archive mappings
        my $cat_sql = 'DELETE FROM lrr_category_to_archive_map WHERE arcid = ?';
        my $cat_sth = $dbh->prepare($cat_sql);
        $cat_sth->execute($id);
        $cat_sth->finish;

        # Delete from archive-to-tag mappings
        my $tag_sql = 'DELETE FROM lrr_archive_to_tag_map WHERE arcid = ?';
        my $tag_sth = $dbh->prepare($tag_sql);
        $tag_sth->execute($id);
        $tag_sth->finish;

        # Delete the archive entry itself
        my $arc_sql = 'DELETE FROM lrr_archive WHERE arcid = ?';
        my $arc_sth = $dbh->prepare($arc_sql);
        $arc_sth->execute($id);
        $arc_sth->finish;

        $dbh->commit;
        $logger->debug("Successfully deleted archive $id from database");
    };

    if ( my $error = $@ ) {
        $logger->error("Error deleting archive $id: $error");
        eval { $dbh->rollback };
        $dbh->disconnect();
        return "0";
    }

    $dbh->disconnect();

    # Delete the file from filesystem if it exists
    if ( $filename && -e $filename ) {
        my $status = unlink_path( $filename );

        my $thumbdir  = LANraragi::Model::Config->get_thumbdir;
        my $subfolder = substr( $id, 0, 2 );

        my $jpg_thumbname = "$thumbdir/$subfolder/$id.jpg";
        unlink $jpg_thumbname;

        my $jxl_thumbname = "$thumbdir/$subfolder/$id.jxl";
        unlink $jxl_thumbname;

        # Delete the thumbpages folder
        remove_tree("$thumbdir/$subfolder/$id/");

        return $status ? $filename : "0";
    }

    return "0";
}

# replaces LANraragi::Utils::Archive::extract_thumbnail
# Wrapper function with original signature that manages its own database connection
sub extract_thumbnail ( $thumbdir, $id, $page, $set_cover, $use_hq ) {
    my $dbh = get_postgresql_dbh();
    my $result;
    eval {
        $result = extract_thumbnail_with_dbh( $dbh, $thumbdir, $id, $page, $set_cover, $use_hq );
    };
    my $error = $@;
    $dbh->disconnect();
    die $error if $error;
    return $result;
}

# For transactional contexts where endpoint manages $dbh
sub extract_thumbnail_with_dbh ( $dbh, $thumbdir, $id, $page, $set_cover, $use_hq ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    # JPG is used for thumbnails by default
    my $use_jxl = LANraragi::Model::Config->get_jxlthumbpages;
    my $format  = $use_jxl ? 'jxl' : 'jpg';

    # Another subfolder with the first two characters of the id is used for FS optimization.
    my $subfolder = substr( $id, 0, 2 );
    make_path("$thumbdir/$subfolder");

    my $file = get_archive_path( $dbh, $id );

    # Get first image from archive using filelist
    my @filelist        = get_filelist($file, $id);
    my $requested_image = $filelist[ $page > 0 ? $page - 1 : 0 ];

    die "Requested image not found: $id page $page" unless $requested_image;
    $logger->debug("Extracting thumbnail for $id page $page from $requested_image");

    # Extract requested image to temp dir if it doesn't already exist
    my $arcimg = extract_single_file( $file, $requested_image );

    my $thumbname;
    unless ($set_cover) {

        # Non-cover thumbnails land in a dedicated folder.
        $thumbname = "$thumbdir/$subfolder/$id/$page.$format";
        make_path("$thumbdir/$subfolder/$id");
    } else {

        $thumbname = "$thumbdir/$subfolder/$id.$format";

        # For cover thumbnails, grab the SHA-1 hash for tag research.
        # That way, no need to repeat a costly extraction later.
        my $shasum = shasum_str( $arcimg, 1 );
        $logger->debug("Setting thumbnail hash: $shasum");

        # Update thumbhash
        eval {
            my $sth = $dbh->prepare('UPDATE lrr_archive SET thumbhash = ? WHERE arcid = ?');
            $sth->execute($shasum, $id);
            $sth->finish;
        };
        if ( my $error = $@ ) {
            $logger->error("Error updating thumbhash for $id: $error");
            die $error;
        }
    }

    # Thumbnail generation
    no warnings 'experimental::try';
    try {
        generate_thumbnail( $arcimg, $thumbname, $use_hq, $use_jxl );
    } catch ($e) {
        $logger->error("Thumbnail generation failed for archive '$file' entry '$requested_image' -> '$thumbname': $e");
        die $e;
    }

    return $thumbname;
}

1;
