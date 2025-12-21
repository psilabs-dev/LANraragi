package LANraragi::Model::PsilabsDev::PgUpload;

use v5.36;

use strict;
use warnings;

use Config;
use Encode;
use File::Basename;
use Exporter 'import';

our @EXPORT_OK = qw(add_timestamp_tag add_pagecount add_arcsize add_timestamp_tag_with_dbh add_pagecount_with_dbh add_arcsize_with_dbh add_archive_to_postgres);

use LANraragi::Utils::Database qw(compute_id);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Generic  qw(is_archive);
use LANraragi::Utils::String   qw(trim);
use LANraragi::Utils::Path     qw(create_path rename_path move_path unlink_path date_modified);

use LANraragi::Model::Config   qw(get_userdir);
use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Model::PsilabsDev::PgPlugins;
use LANraragi::Utils::PsilabsDev::PgArchive qw(extract_thumbnail);
use LANraragi::Utils::PsilabsDev::PgDatabase qw(set_tags set_title set_summary invalidate_cache);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

# replaces: LANraragi::Model::Upload::handle_incoming_file
# Process a file.
# First argument is the filepath, preferably in a temp directory,
# as we'll copy it to the content folder and delete the original at the end.
#
# The file will be added to a category, if its ID is specified.
# You can also specify tags to add to the metadata for the processed file before autoplugin is ran. (if it's enabled)
#
# Returns an HTTP status code, the ID and title of the file, and a status message.
sub handle_incoming_file ( $tempfile, $catid, $tags, $title, $summary ) {

    my ( $filename, $dirs, $suffix ) = fileparse( $tempfile, qr/\.[^.]*/ );
    $filename = $filename . $suffix;
    my $logger = get_logger( "File Upload/Download", "lanraragi" );

    # Check if file is an archive
    unless ( is_archive($filename) ) {
        $logger->debug("$filename is not an archive, halting upload process.");
        return ( 415, "deadbeef", $filename, "Unsupported File Extension ($filename)" );
    }

    # Compute an ID here
    my $id = compute_id($tempfile);
    $logger->debug("ID of uploaded file $filename is $id");

    # Future home of the file
    my $userdir     = LANraragi::Model::Config->get_userdir;
    my $output_file = create_path( $userdir . '/' . $filename );

    # Check if the ID is already in the database, and
    # that the file it references still exists on the filesystem
    my $dbh          = get_postgresql_dbh();
    my $replace_dupe = LANraragi::Model::Config->get_replacedupe;

    my $check_sql = 'SELECT arcid, filename FROM lrr_archive WHERE arcid = ?';
    my $check_sth = $dbh->prepare($check_sql);
    $check_sth->execute($id);
    my $existing_row = $check_sth->fetchrow_hashref;
    $check_sth->finish;

    my $isdupe = 0;
    if ($existing_row) {
        # Check if the file still exists on filesystem
        my $existing_file = $existing_row->{filename};
        $isdupe = -e $existing_file;
    }

    # Stop here if file is a dupe and replacement is turned off.
    if ( ( -e $output_file || $isdupe ) && !$replace_dupe ) {

        # Trash temporary file
        unlink_path $tempfile;

        # The file already exists
        my $suffix = " Enable replace duplicated archive in config to replace old ones.";
        my $msg =
          $isdupe
          ? "This file already exists in the Library." . $suffix
          : "A file with the same name is present in the Library." . $suffix;

        $dbh->disconnect();
        return ( 409, $id, $filename, $msg );
    }

    # If we are replacing an existing one, just remove the old one first.
    if ($replace_dupe) {
        $logger->debug("Delete archive $id before replacing it.");
        LANraragi::Utils::PsilabsDev::PgArchive::delete_archive($id);
    }

    # Add the file to the database ourselves
    # This allows autoplugin to be ran ASAP.
    my $name = add_archive_to_postgres( $id, (IS_UNIX ? encode_utf8( $output_file ) : $output_file), $dbh );

    # If additional tags were given to the sub, add them now.
    if ($tags) {
        set_tags( $id, $tags );
    }

    # Set title
    if ($title) {
        set_title( $id, $title );
    }

    # Set summary
    if ($summary) {
        set_summary( $id, $summary );
    }

    $dbh->disconnect();

    # Move the file to the content folder.
    # Move to a .upload first in case copy to the content folder takes a while...
    move_path( $tempfile, $output_file . ".upload" )
      or return ( 500, $id, $name, "The file couldn't be moved to your content folder: $!" );

    # Then rename inside the content folder itself to proc Shinobu's filemap update.
    rename_path( $output_file . ".upload", $output_file )
      or return ( 500, $id, $name, "The file couldn't be renamed in your content folder: $!" );

    # If the move didn't signal an error, but still doesn't exist, something is quite spooky indeed!
    # Really funky permissions that prevents viewing folder contents?
    unless ( -e $output_file ) {
        return ( 500, $id, $name, "The file couldn't be moved to your content folder!" );
    }

    # Now that the file has been copied, we can add the timestamp tag and calculate pagecount.
    # (The file being physically present is necessary in case last modified time is used)
    add_timestamp_tag( $id );
    add_pagecount( $id );
    add_arcsize( $id );

    # Generate thumbnail
    my $thumbdir = LANraragi::Model::Config->get_thumbdir;
    extract_thumbnail( $thumbdir, $id, 1, 1, 1 );

    $logger->debug("Running autoplugin on newly uploaded file $id...");

    my ( $succ, $fail, $addedtags, $newtitle ) = LANraragi::Model::PsilabsDev::PgPlugins::exec_enabled_plugins_on_file($id);
    my $successmsg = "$succ Plugins used successfully, $fail Plugins failed, $addedtags tags added. ";

    if ( $newtitle ne "" ) {
        $name = $newtitle;
    }

    if ($catid) {
        $logger->debug("Adding uploaded file to category $catid");

        my ( $catsucc, $caterr ) = LANraragi::Model::PsilabsDev::PgCategory::add_to_category( $catid, $id );
        if ($catsucc) {
            # Fetch category name
            my $dbh = get_postgresql_dbh();
            my $cat_sql = 'SELECT name FROM lrr_category WHERE catid = ?';
            my $cat_sth = $dbh->prepare($cat_sql);
            $cat_sth->execute($catid);
            my $cat_row = $cat_sth->fetchrow_hashref;
            $cat_sth->finish();
            my $catname = $cat_row ? $cat_row->{name} : "Unknown";
            $dbh->disconnect();

            $successmsg .= "Added to Category '$catname'!";
        } else {
            $successmsg .= "Couldn't add to Category: $caterr";
        }
    }

    # Postgres doesn't need cache invalidation
    invalidate_cache();

    return ( 200, $id, $name, $successmsg );
}

# Helper function: add_archive_to_postgres
# Creates a DB entry for a file path with the given ID.
# This is the Postgres equivalent of add_archive_to_redis.
sub add_archive_to_postgres ( $id, $file, $dbh ) {

    my $logger = get_logger( "Archive", "lanraragi" );
    my ( $name, $path, $suffix ) = fileparse( $file, qr/\.[^.]*/ );

    # Initialize Postgres entry for the added file
    $logger->debug("Pushing to Postgres on ID $id:");
    $logger->debug("File Name: $name");
    $logger->debug("Filesystem Path: $file");

    my $arcsize = 0;
    if ( defined($file) && -e $file ) {
        $arcsize = -s $file;
    }

    # Insert the archive into the database
    my $sql = <<'SQL';
        INSERT INTO lrr_archive (arcid, filename, extension, isnew, lastreadtime, pagecount, progress, title, summary, thumbhash, arcsize)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (arcid) DO UPDATE SET
            filename = EXCLUDED.filename,
            extension = EXCLUDED.extension,
            isnew = EXCLUDED.isnew,
            lastreadtime = EXCLUDED.lastreadtime,
            pagecount = EXCLUDED.pagecount,
            progress = EXCLUDED.progress,
            title = EXCLUDED.title,
            arcsize = EXCLUDED.arcsize
SQL

    my $sth = $dbh->prepare($sql);
    $sth->execute(
        $id,
        $file,
        $suffix,
        1,           # isnew = true
        0,           # lastreadtime = 0
        0,           # pagecount = 0
        0,           # progress = 0
        $name,       # title = filename without extension
        '',          # summary = empty
        '',          # thumbhash = empty
        $arcsize     # arcsize
    );
    $sth->finish;

    # Update the search_tsv column for full-text search
    # Include arcid in the initial population (tags will be added later via set_tags_with_dbh)
    my $update_tsv_sql = <<'SQL';
        UPDATE lrr_archive
        SET search_tsv = to_tsvector('simple', COALESCE(arcid, '') || ' ' || COALESCE(title, ''))
        WHERE arcid = ?
SQL

    my $tsv_sth = $dbh->prepare($update_tsv_sql);
    $tsv_sth->execute($id);
    $tsv_sth->finish;

    return $name;
}

# Helper function: add_timestamp_tag
# Adds a timestamp tag to the given ID.
sub add_timestamp_tag ( $id ) {
    my $dbh = get_postgresql_dbh();
    my $result = add_timestamp_tag_with_dbh( $dbh, $id );
    $dbh->disconnect();
    return $result;
}

# Helper function: add_timestamp_tag_with_dbh
# Adds a timestamp tag to the given ID, using provided database handle.
sub add_timestamp_tag_with_dbh ( $dbh, $id ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    # Initialize tags to the current date if the matching pref is enabled
    if ( LANraragi::Model::Config->enable_dateadded eq "1" ) {

        $logger->debug("Adding timestamp tag...");
        my $date;

        if ( LANraragi::Model::Config->use_lastmodified eq "1" ) {
            $logger->debug("Using file date");
            # Get the file path from database
            my $sql = 'SELECT filename FROM lrr_archive WHERE arcid = ?';
            my $sth = $dbh->prepare($sql);
            $sth->execute($id);
            my $row = $sth->fetchrow_hashref;
            my $filepath = $row ? $row->{filename} : '';
            $sth->finish;

            if ($filepath && -e $filepath) {
                $date = date_modified($filepath);
            } else {
                $date = time();
            }
        } else {
            $logger->debug("Using current date");
            $date = time();
        }

        set_tags( $id, "date_added:$date", 1 );
    }
}

# Helper function: add_pagecount
# Adds pagecount to the archive metadata.
sub add_pagecount ( $id ) {
    my $dbh = get_postgresql_dbh();
    my $result = add_pagecount_with_dbh( $dbh, $id );
    $dbh->disconnect();
    return $result;
}

# Helper function: add_pagecount_with_dbh
# Adds pagecount to the archive metadata, using provided database handle.
sub add_pagecount_with_dbh ( $dbh, $id ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    # Get the file path
    my $sql = 'SELECT filename FROM lrr_archive WHERE arcid = ?';
    my $sth = $dbh->prepare($sql);
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    my $filepath = $row ? $row->{filename} : '';
    $sth->finish;

    if (!$filepath || !-e $filepath) {
        $logger->warn("Cannot calculate pagecount for $id - file not found");
        return;
    }

    # Calculate pagecount using Archive utility
    use LANraragi::Utils::Archive qw(get_filelist);
    my @files = get_filelist($filepath, $id);
    my $pagecount = scalar @files;

    # Update pagecount in database
    my $update_sql = 'UPDATE lrr_archive SET pagecount = ? WHERE arcid = ?';
    my $update_sth = $dbh->prepare($update_sql);
    $update_sth->execute($pagecount, $id);
    $update_sth->finish;

    $logger->debug("Set pagecount for $id to $pagecount");
}

# Helper function: add_arcsize
# Adds archive size to the archive metadata.
sub add_arcsize ( $id ) {
    my $dbh = get_postgresql_dbh();
    my $result = add_arcsize_with_dbh( $dbh, $id );
    $dbh->disconnect();
    return $result;
}

# Helper function: add_arcsize_with_dbh
# Adds archive size to the archive metadata, using provided database handle.
sub add_arcsize_with_dbh ( $dbh, $id ) {

    my $logger = get_logger( "Archive", "lanraragi" );

    # Get the file path
    my $sql = 'SELECT filename FROM lrr_archive WHERE arcid = ?';
    my $sth = $dbh->prepare($sql);
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    my $filepath = $row ? $row->{filename} : '';
    $sth->finish;

    if (!$filepath || !-e $filepath) {
        $logger->warn("Cannot calculate arcsize for $id - file not found");
        return;
    }

    my $arcsize = -s $filepath;

    # Update arcsize in the database
    my $update_sql = 'UPDATE lrr_archive SET arcsize = ? WHERE arcid = ?';
    my $update_sth = $dbh->prepare($update_sql);
    $update_sth->execute($arcsize, $id);
    $update_sth->finish;

    $logger->debug("Set arcsize for $id to $arcsize bytes");
}

1;
