package LANraragi::Utils::PsilabsDev::PgPath;

use v5.36;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_archive_path);

use LANraragi::Utils::Path qw(create_path);

# replaces LANraragi::Utils::Path::get_archive_path
sub get_archive_path ( $dbh, $id ) {
    my $sth = $dbh->prepare('SELECT filename FROM lrr_archive WHERE arcid = ?');
    $sth->execute($id);
    my $row = $sth->fetchrow_hashref;
    $sth->finish;

    return unless $row;
    return create_path( $row->{filename} );
}

1;
