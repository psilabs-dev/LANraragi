package LANraragi::Controller::Stats;
use Mojo::Base 'Mojolicious::Controller';

use LANraragi::Model::PsilabsDev::PgStats;
use LANraragi::Utils::Generic qw(generate_themes_header);

# This action will render a template
sub index {
    my $self = shift;

    $self->render(
        template     => "stats",
        title        => $self->LRR_CONF->get_htmltitle,
        descstr      => $self->LRR_DESC,
        csshead      => generate_themes_header($self),
        archivecount => LANraragi::Model::PsilabsDev::PgStats::get_archive_count,
        arcsize      => LANraragi::Model::PsilabsDev::PgStats::compute_content_size,
        pagestat     => LANraragi::Model::PsilabsDev::PgStats::get_page_stat,
        version      => $self->LRR_VERSION
    );
}

1;
