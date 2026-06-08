package LANraragi::Model::PsilabsDev::PgStamp;

use strict;
use warnings;
use utf8;

use Time::HiRes qw(time);

use LANraragi::Utils::PsilabsDev::Database qw(get_dbh);
use LANraragi::Utils::Logging qw(get_logger);

# Postgres-side equivalent of LANraragi::Model::Stamp. Stamps are per-page annotations stored in the
# lrr_stamp table (stampid, arcid, page, content, position). The stampid keeps the upstream
# "STAMPS_<page>_<timestamp_ms>" key format for API compatibility. content/position are stored as
# native UTF-8 (DBD::Pg with pg_enable_utf8) -- no redis_encode/redis_decode on this path.

# replaces LANraragi::Model::Stamp::get_stamp
# get_stamp(stamp_id)
#   Returns (\%stamp, $err) with keys content/position/id, or an empty list if the stamp doesn't exist.
sub get_stamp {
    my ($stamp_id) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );

    if ( $stamp_id eq "" ) {
        $logger->debug("No stamp ID provided.");
        return ();
    }

    my $dbh = get_dbh();
    my $sth = $dbh->prepare('SELECT content, position FROM lrr_stamp WHERE stampid = ?');
    $sth->execute($stamp_id);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    $dbh->disconnect();

    unless ($row) {
        $logger->warn("$stamp_id doesn't exist in the database!");
        return ();
    }

    my %stamp = (
        content  => $row->{content} // "",
        position => $row->{position} // "",
        id       => $stamp_id
    );

    return ( \%stamp, "" );
}

# replaces LANraragi::Model::Stamp::get_stamps_by_page
# get_stamps_by_page(archive_id, page)
#   Returns (\@stamps, $err) -- the stamps attached to the given archive page.
sub get_stamps_by_page {
    my ( $archive_id, $index ) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );
    my $dbh    = get_dbh();

    unless ( _archive_exists( $dbh, $archive_id ) ) {
        $dbh->disconnect();
        my $err = "$archive_id does not exist in the database.";
        $logger->error($err);
        return ( 0, $err );
    }

    my $sth = $dbh->prepare('SELECT stampid, content, position FROM lrr_stamp WHERE arcid = ? AND page = ?');
    $sth->execute( $archive_id, $index );

    my @stamps;
    while ( my $row = $sth->fetchrow_hashref ) {
        push @stamps,
          {
            content  => $row->{content} // "",
            position => $row->{position} // "",
            id       => $row->{stampid}
          };
    }
    $sth->finish;
    $dbh->disconnect();

    return ( \@stamps, "" );
}

# replaces LANraragi::Model::Stamp::get_stamped_pages
# get_stamped_pages(archive_id)
#   Returns (\@pages, $err) -- the distinct page numbers that have at least one stamp.
sub get_stamped_pages {
    my ($archive_id) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );
    my $dbh    = get_dbh();

    unless ( _archive_exists( $dbh, $archive_id ) ) {
        $dbh->disconnect();
        my $err = "$archive_id does not exist in the database.";
        $logger->error($err);
        return ( 0, $err );
    }

    my $sth = $dbh->prepare('SELECT DISTINCT page FROM lrr_stamp WHERE arcid = ?');
    $sth->execute($archive_id);

    my @pages;
    while ( my $row = $sth->fetchrow_arrayref ) {
        push @pages, $row->[0];
    }
    $sth->finish;
    $dbh->disconnect();

    return ( \@pages, "" );
}

# replaces LANraragi::Model::Stamp::add_stamp
# add_stamp(archive_id, index, content, position)
#   Adds a stamp to the given archive page. Returns ($stampid, $err); ($err is empty on success).
sub add_stamp {
    my ( $archive_id, $index, $content, $position ) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );
    my $dbh    = get_dbh();

    my $sth = $dbh->prepare('SELECT pagecount FROM lrr_archive WHERE arcid = ?');
    $sth->execute($archive_id);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    unless ($row) {
        $dbh->disconnect();
        my $err = "$archive_id does not exist in the database.";
        $logger->error($err);
        return ( 0, $err );
    }

    my $pagecount = $row->{pagecount} || 0;
    unless ( int($index) <= int($pagecount) && int($index) > 0 ) {
        $dbh->disconnect();
        my $err = "Page $index out of range.";
        $logger->error($err);
        return ( 0, $err );
    }

    my $key      = "STAMPS_" . $index . "_" . int( time() * 1000 );
    my $check    = $dbh->prepare('SELECT 1 FROM lrr_stamp WHERE stampid = ?');
    my $isnewkey = 0;
    until ($isnewkey) {
        $check->execute($key);
        if ( $check->fetchrow_arrayref ) {
            $key = "STAMPS_" . $index . "_" . int( time() * 1000 + 1 );
        } else {
            $isnewkey = 1;
        }
    }
    $check->finish;

    my $ins = $dbh->prepare('INSERT INTO lrr_stamp (stampid, arcid, page, content, position) VALUES (?, ?, ?, ?, ?)');
    $ins->execute( $key, $archive_id, int($index), $content, $position );
    $ins->finish;
    $dbh->disconnect();

    return ( $key, "" );
}

# replaces LANraragi::Model::Stamp::update_stamp
# update_stamp(stamp_id, content, position)
#   Updates the stamp's content and/or position (only the defined fields). Returns (1, "") on success,
#   (0, error) if the stamp doesn't exist.
sub update_stamp {
    my ( $stamp_id, $content, $position ) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );
    my $dbh    = get_dbh();

    my $chk = $dbh->prepare('SELECT 1 FROM lrr_stamp WHERE stampid = ?');
    $chk->execute($stamp_id);
    my $exists = $chk->fetchrow_arrayref;
    $chk->finish;

    unless ($exists) {
        $dbh->disconnect();
        my $err = "$stamp_id doesn't exist in the database!";
        $logger->warn($err);
        return ( 0, $err );
    }

    if ( defined $position ) {
        my $sth = $dbh->prepare('UPDATE lrr_stamp SET position = ? WHERE stampid = ?');
        $sth->execute( $position, $stamp_id );
        $sth->finish;
    }

    if ( defined $content ) {
        my $sth = $dbh->prepare('UPDATE lrr_stamp SET content = ? WHERE stampid = ?');
        $sth->execute( $content, $stamp_id );
        $sth->finish;
    }

    $dbh->disconnect();
    return ( 1, "" );
}

# replaces LANraragi::Model::Stamp::remove_stamp
# remove_stamp(stamp_id)
#   Removes the stamp. Returns (1, "") on success, (0, error) if the stamp doesn't exist.
sub remove_stamp {
    my ($key) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );
    my $dbh    = get_dbh();

    my $del  = $dbh->prepare('DELETE FROM lrr_stamp WHERE stampid = ?');
    my $rows = $del->execute($key);
    $del->finish;
    $dbh->disconnect();

    unless ( $rows && $rows > 0 ) {
        my $err = "$key doesn't exist in the database!";
        $logger->warn($err);
        return ( 0, $err );
    }

    return ( 1, "" );
}

# replaces LANraragi::Model::Stamp::get_stamp_archive_id
# get_stamp_archive_id(stamp_id)
#   Returns (1, archive_id) if the stamp exists, otherwise (0, error message).
sub get_stamp_archive_id {
    my ($key) = @_;

    my $logger = get_logger( "PgStamp", "lanraragi" );
    my $dbh    = get_dbh();

    my $sth = $dbh->prepare('SELECT arcid FROM lrr_stamp WHERE stampid = ?');
    $sth->execute($key);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;
    $dbh->disconnect();

    unless ($row) {
        my $err = "$key doesn't exist in the database!";
        $logger->warn($err);
        return ( 0, $err );
    }

    return ( 1, $row->{arcid} );
}

# Returns true if the archive exists. Uses the caller's $dbh (does not disconnect it).
sub _archive_exists {
    my ( $dbh, $archive_id ) = @_;

    my $sth = $dbh->prepare('SELECT 1 FROM lrr_archive WHERE arcid = ?');
    $sth->execute($archive_id);
    my $exists = $sth->fetchrow_arrayref;
    $sth->finish;

    return $exists ? 1 : 0;
}

1;
