package LANraragi::Controller::Api::Archive;
use Mojo::Base 'Mojolicious::Controller';

use Digest::SHA qw(sha1_hex);
use Redis;
use Config;
use Encode;
use Storable;
use Scalar::Util qw(looks_like_number);

use File::Temp qw(tempdir tmpnam);
use File::Basename;

use LANraragi::Utils::Generic  qw(render_api_response is_archive get_bytelength exec_with_lock);
use LANraragi::Utils::Database qw();
use LANraragi::Utils::PsilabsDev::PgDatabase qw(get_archive_json set_isnew);
use LANraragi::Utils::Logging  qw(get_logger);
use LANraragi::Utils::Redis    qw(redis_encode);
use LANraragi::Utils::Path     qw(compat_path get_archive_path move_path);
use LANraragi::Utils::PsilabsDev::Postgres qw(get_postgresql_dbh);
use LANraragi::Utils::PsilabsDev::PgPath;

use LANraragi::Utils::Login qw(is_logged_in_api);

use LANraragi::Model::Archive;
use LANraragi::Model::Config;
use LANraragi::Model::Reader;
use LANraragi::Model::PsilabsDev::PgArchive;
use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Model::PsilabsDev::PgReader;
use LANraragi::Model::PsilabsDev::PgUpload;

use constant IS_UNIX => ( $Config{osname} ne 'MSWin32' );

# Archive API.


sub serve_archivelist {
    my $self   = shift->openapi->valid_input or return;
    my @idlist = LANraragi::Model::PsilabsDev::PgArchive::generate_archive_list();
    $self->render( openapi => \@idlist );
}

sub serve_untagged_archivelist {
    my $self = shift->openapi->valid_input or return;
    my @untagged = LANraragi::Model::PsilabsDev::PgArchive::get_untagged_archives();
    $self->render( openapi => \@untagged );
}

sub serve_metadata {
    my $self  = shift->openapi->valid_input or return;
    my $id    = $self->stash('id');
    my $dbh   = get_postgresql_dbh();

    my $arcdata = get_archive_json( $dbh, $id );
    $dbh->disconnect();

    if ($arcdata) {
        $self->render( openapi => $arcdata );
    } else {
        $self->render(
            json => {
                operation => "metadata",
                success   => 0,
                error     => "This ID doesn't exist on the server."
            },
            status => 404
        );
    }
}

# Find which categories this ID is saved in.
sub get_categories {

    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my @categories = LANraragi::Model::PsilabsDev::PgCategory::get_categories_containing_archive($id);

    $self->render(
        openapi => {
            operation  => "find_arc_categories",
            categories => \@categories,
            success    => 1
        }
    );
}

sub serve_thumbnail {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    LANraragi::Model::Archive::serve_thumbnail( $self, $id );
}

sub update_thumbnail {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    LANraragi::Model::PsilabsDev::PgArchive::update_thumbnail( $self, $id );
}

sub generate_page_thumbnails {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    LANraragi::Model::PsilabsDev::PgArchive::generate_page_thumbnails( $self, $id );
}

# Use RenderFile to get the file of the provided id to the client.
sub serve_file {

    my $self  = shift->openapi->valid_input or return;
    my $id    = $self->stash('id');
    my $dbh = get_postgresql_dbh();

    my $file = LANraragi::Utils::PsilabsDev::PgPath::get_archive_path( $dbh, $id );
    $dbh->disconnect();
    $self->render_file( filepath => compat_path( $file ), filename => basename( $file ) );
}

# Create a file archive along with any metadata.
# adapted from Upload.pm
sub create_archive {
    my $self   = shift->openapi->valid_input or return;
    my $logger = get_logger( "Archive API ", "lanraragi" );

    # receive uploaded file
    my $upload            = $self->req->upload('file');
    my $expected_checksum = $self->req->param('file_checksum');    # optional

    # require file
    if ( !defined $upload || !$upload ) {
        return $self->render(
            openapi => {
                operation => "upload",
                success   => 0,
                error     => "No file attached"
            },
            status => 400
        );
    }

    # checksum verification stage.
    if ($expected_checksum) {
        my $file_content    = $upload->slurp;
        my $actual_checksum = sha1_hex($file_content);
        if ( $expected_checksum ne $actual_checksum ) {
            return $self->render(
                openapi => {
                    operation => "upload",
                    success   => 0,
                    error     => "Checksum mismatch: expected $expected_checksum, got $actual_checksum."
                },
                status => 417
            );
        }
    }

    my $filename   = encode_utf8( $upload->filename );
    my $uploadMime = $upload->headers->content_type;

    return unless exec_with_lock(
        $self,
        "upload:$filename",
        "upload",
        $filename,
        sub {

            # metadata extraction
            my $catid   = $self->req->param('category_id');
            my $tags    = $self->req->param('tags');
            my $title   = $self->req->param('title');
            my $summary = $self->req->param('summary');

            # return error if archive is not supported.
            if ( !is_archive($filename) ) {
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => "Unsupported file extension ($filename)"
                    },
                    status => 415
                );
            }

            # Move file to a temp folder (not the default LRR one)
            my $tempdir = tempdir();

            my ( $fn, $path, $ext ) = fileparse( $filename, qr/\.[^.]*/ );
            my $byte_limit = LANraragi::Model::Config->enable_cryptofs ? 143 : 255;

            $filename = $fn;
            while ( get_bytelength( $filename . $ext . ".upload" ) > $byte_limit ) {
                $filename = substr( $filename, 0, -1 );
            }
            $filename = $filename . $ext;

            my $tempfile = $tempdir . '/' . $filename;

            # On Windows Mojo will hold an open handle to the upload file preventing us from using the long-path compatible
            # methods to move it.
            # Workaround it by using another temp file as a target for Mojo's move_to so that the original handle can be closed.
            my $mojo_temp = tmpnam();
            if ( !$upload->move_to($mojo_temp) ) {
                $logger->error("Could not move uploaded file $filename to $mojo_temp");
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => "Couldn't move uploaded file to temporary location."
                    },
                    status => 500
                );
            }

            if ( !move_path( $mojo_temp, $tempfile ) ) {    # Move the file for real this time
                $logger->error("Could not move uploaded file $mojo_temp to $tempfile");
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => "Couldn't move uploaded file to temporary location."
                    },
                    status => 500
                );
            }

            if (IS_UNIX) {
                $tempfile = decode_utf8($tempfile);
            }

            my ( $status_code, $id, $response_title, $message ) =
              LANraragi::Model::PsilabsDev::PgUpload::handle_incoming_file( $tempfile, $catid, $tags, $title, $summary );

            unless ( $status_code == 200 ) {
                return $self->render(
                    openapi => {
                        operation => "upload",
                        success   => 0,
                        error     => $message,
                        id        => $id
                    },
                    status => $status_code
                );
            }

            return $self->render(
                openapi => {
                    operation => "upload",
                    success   => 1,
                    id        => $id
                },
                status => 200
            );
        }
    );
}

# Serve an archive page from the temporary folder, using RenderFile.
sub serve_page {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');
    my $path = $self->req->param('path')                 || "404.xyz";

    LANraragi::Model::PsilabsDev::PgArchive::serve_page( $self, $id, $path );
}

sub get_file_list {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $force = $self->req->param('force') eq "true" || "0";
    my $reader_json;

    eval { $reader_json = LANraragi::Model::PsilabsDev::PgReader::build_reader_JSON( $self, $id, $force ); };
    my $err = $@;

    if ($err) {
        render_api_response( $self, "get_file_list", $err );
    } else {
        $self->render( openapi => $reader_json );
    }
}

sub add_new {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "add_new",
        $id,
        sub {
            set_isnew( $id, "true" );
            render_api_response( $self, "add_new" );
        }
    );
}

sub clear_new {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "clear_new",
        $id,
        sub {
            set_isnew( $id, "false" );

            $self->render(
                openapi => {
                    operation => "clear_new",
                    id        => $id,
                    success   => 1
                }
            );
        }
    );
}

sub delete_archive {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "delete_archive",
        $id,
        sub {
            my $delStatus = LANraragi::Model::PsilabsDev::PgArchive::delete_archive($id);

            $self->render(
                openapi => {
                    operation => "delete_archive",
                    id        => $id,
                    filename  => decode_utf8($delStatus),
                    success   => $delStatus eq "0" ? 0 : 1
                }
            );
        }
    );
}

sub update_metadata {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $title   = $self->req->param('title');
    my $tags    = $self->req->param('tags');
    my $summary = $self->req->param('summary');

    # Check if archive exists before acquiring lock
    unless ( LANraragi::Model::PsilabsDev::PgArchive::archive_exists($id) ) {
        $self->render(
            json => {
                operation => "update_metadata",
                success   => 0,
                error     => "Archive with ID $id not found."
            },
            status => 404
        );
        return;
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "update_metadata",
        $id,
        sub {
            my $err = LANraragi::Model::PsilabsDev::PgArchive::update_metadata( $id, $title, $tags, $summary );

            if ( $err eq "" ) {
                my $title          = LANraragi::Model::PsilabsDev::PgArchive::get_title($id);
                my $successMessage = "Updated metadata for \"$title\"!";

                render_api_response( $self, "update_metadata", undef, $successMessage );
            } else {
                render_api_response( $self, "update_metadata", $err );
            }
        }
    );
}

sub add_toc {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $page  = $self->req->param('page');
    my $title = $self->req->param('title');

    unless ( defined $page && defined $title ) {
        return render_api_response( $self, "add_toc", "Missing page and/or title." );
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "add_toc",
        $id,
        sub {
            my $res = LANraragi::Model::PsilabsDev::PgArchive::add_toc_entry( $id, $page, $title );

            if ( $res eq "" ) {
                render_api_response( $self, "add_toc", undef, "Added ToC entry for page $page." );
            } else {
                render_api_response( $self, "add_toc", $res );
            }
        }
    );

}

sub remove_toc {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    my $page = $self->req->param('page');

    unless ( defined $page ) {
        return render_api_response( $self, "remove_toc", "Please specify a page to remove" );
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "remove_toc",
        $id,
        sub {
            my $res = LANraragi::Model::PsilabsDev::PgArchive::remove_toc_entry( $id, $page );

            if ( $res eq "" ) {
                render_api_response( $self, "remove_toc", undef, "Removed ToC entry for page $page." );
            } else {
                render_api_response( $self, "remove_toc", $res );
            }
        }
    );
}

sub update_progress {
    my $self = shift->openapi->valid_input or return;
    my $id   = $self->stash('id');

    # Enforce authentication if authprogress is enabled
    if ( LANraragi::Model::Config->enable_authprogress ) {
        unless ( is_logged_in_api($self) ) {
            return $self->render(
                openapi => {
                    operation => "update_progress",
                    error     => "This operation requires authentication.",
                    success   => 0
                },
                status => 401
            );
        }
    }

    my $page = $self->stash('page') || 0;

    # Undocumented parameter to force progress update
    my $force = $self->req->param('force') || 0;

    if ( LANraragi::Model::Config->enable_localprogress && !LANraragi::Model::Config->enable_authprogress ) {
        render_api_response( $self, "update_progress", "Server-side Progress Tracking is disabled on this instance." );
        return;
    }

    return unless exec_with_lock(
        $self,
        "archive-write:$id",
        "update_progress",
        $id,
        sub {
            my $result;

            eval {
                $result = LANraragi::Model::PsilabsDev::PgArchive::update_progress( $id, $page, $force );
            };

            if ( my $error = $@ ) {
                render_api_response( $self, "update_progress", $error );
                return;
            }

            my $pagecount = $result->{pagecount};

            # This relies on pagecount, so you can't update progress for archives that don't have a valid pagecount recorded yet.
            unless ( $pagecount || $force ) {
                render_api_response( $self, "update_progress", "Archive doesn't have a total page count recorded yet." );
                return;
            }

            # Safety-check the given page value.
            unless ( $force || ( looks_like_number($page) && $page > 0 && $page <= $pagecount ) ) {
                render_api_response( $self, "update_progress", "Invalid progress value." );
                return;
            }

            $self->render(
                openapi => {
                    operation    => "update_progress",
                    id           => $id,
                    page         => $page,
                    lastreadtime => $result->{lastreadtime},
                    success      => 1
                }
            );
        }
    );
}

1;
