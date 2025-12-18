package LANraragi::Utils::PsilabsDev::PgPath;

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(get_archive_path);

use LANraragi::Model::PsilabsDev::PgArchive qw(get_archive_filename);
use LANraragi::Utils::Path qw(create_path);

# replaces: LANraragi::Utils::Path::get_archive_path
# get_archive_path($arcid)
#   Returns the full path to an archive file using Postgres database.
#   Queries the database for the filename and creates the proper path format.
sub get_archive_path {
    my ($arcid) = @_;

    my $filename = get_archive_filename($arcid);
    return create_path($filename);
}

1;
