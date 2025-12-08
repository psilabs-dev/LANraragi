package LANraragi::Controller::Api::Database;
use Mojo::Base 'Mojolicious::Controller';

use Redis;
use Mojo::JSON qw(decode_json);

use LANraragi::Model::Backup;
use LANraragi::Model::PsilabsDev::PgBackup;
use LANraragi::Model::PsilabsDev::PgStats;
use LANraragi::Utils::Generic qw(render_api_response);
use LANraragi::Utils::PsilabsDev::PgDatabase;

sub serve_backup {
    my $self = shift->openapi->valid_input or return;
    $self->render( openapi => decode_json(LANraragi::Model::PsilabsDev::PgBackup::build_backup_JSON) );
}

sub drop_database {
    my $self = shift->openapi->valid_input or return;
    LANraragi::Utils::PsilabsDev::PgDatabase::drop_database();

    # Force a refresh (no-op for Postgres but kept for compatibility)
    LANraragi::Utils::PsilabsDev::PgDatabase::invalidate_cache(1);

    render_api_response( $self, "drop_database" );
}

sub serve_tag_stats {
    my $self = shift->openapi->valid_input or return;
    my $minscore = $self->req->param('minweight') || "1";

    $self->render( openapi => LANraragi::Model::PsilabsDev::PgStats::build_tag_stats($minscore) );
}

sub clean_database {
    my $self = shift->openapi->valid_input or return;
    my ( $deleted, $unlinked ) = LANraragi::Utils::PsilabsDev::PgDatabase::clean_database;

    # Force a refresh (no-op for Postgres but kept for compatibility)
    LANraragi::Utils::PsilabsDev::PgDatabase::invalidate_cache(1);

    $self->render(
        openapi => {
            operation => "clean_database",
            deleted   => $deleted,
            unlinked  => $unlinked,
            success   => 1
        }
    );
}

#Clear new flag in all archives.
sub clear_new_all {

    my $self = shift->openapi->valid_input or return;

    LANraragi::Utils::PsilabsDev::PgDatabase::clear_new_all();

    render_api_response( $self, "clear_new_all" );
}

1;

