package LANraragi::Controller::Api::Database;
use Mojo::Base 'Mojolicious::Controller';

use Redis;
use Mojo::JSON qw(decode_json);

use LANraragi::Model::Backup;
use LANraragi::Model::PsilabsDev::Backup;
use LANraragi::Model::PsilabsDev::Stats;
use LANraragi::Utils::Generic qw(render_api_response);
use LANraragi::Utils::PsilabsDev::DatabaseUtils;

sub serve_backup {
    my $self = shift->openapi->valid_input or return;
    $self->render( openapi => decode_json(LANraragi::Model::PsilabsDev::Backup::build_backup_JSON) );
}

sub drop_database {
    my $self = shift->openapi->valid_input or return;
    LANraragi::Utils::PsilabsDev::DatabaseUtils::drop_database();

    # Force a refresh (no-op for Postgres but kept for compatibility)
    LANraragi::Utils::PsilabsDev::DatabaseUtils::invalidate_cache(1);

    render_api_response( $self, "drop_database" );
}

sub serve_tag_stats {
    my $self = shift->openapi->valid_input or return;
    my $minscore = $self->req->param('minweight') || "1";

    $self->render( openapi => LANraragi::Model::PsilabsDev::Stats::build_tag_stats($minscore) );
}

sub clean_database {
    my $self = shift->openapi->valid_input or return;
    my ( $deleted, $unlinked ) = LANraragi::Utils::PsilabsDev::DatabaseUtils::clean_database;

    # Force a refresh (no-op for Postgres but kept for compatibility)
    LANraragi::Utils::PsilabsDev::DatabaseUtils::invalidate_cache(1);

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

    LANraragi::Utils::PsilabsDev::DatabaseUtils::clear_new_all();

    render_api_response( $self, "clear_new_all" );
}

1;

