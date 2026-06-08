package LANraragi::Controller::Edit;
use Mojo::Base 'Mojolicious::Controller';

use File::Basename;
use Encode;
use Template;

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Plugins qw(get_plugins);
use LANraragi::Model::PsilabsDev::PgTankoubon;
use LANraragi::Utils::PsilabsDev::PgDatabase qw(get_archive);

sub index {
    my $self = shift;

    # Does the passed file exist in the database?
    my $id = $self->req->param('id');

    # Tankoubon IDs follow the pattern TANK_\d{10}
    if ( $id && $id =~ /^TANK_/ ) {
        return $self->edit_tankoubon($id);
    }

    my %hash = get_archive($id);

    if ( %hash ) {
        my ( $name, $title, $tags, $summary, $file, $thumbhash ) = @hash{qw(name title tags summary file thumbhash)};

        #Build plugin listing
        my @pluginlist = get_plugins("metadata");

        $self->render(
            template  => "edit",
            id        => $id,
            name      => $name,
            arctitle  => $title,
            tags      => $tags,
            summary   => $summary,
            file      => decode_utf8($file),
            thumbhash => $thumbhash,
            plugins   => \@pluginlist,
            is_tank   => 0,
            title     => $self->LRR_CONF->get_htmltitle,
            descstr   => $self->LRR_DESC,
            csshead   => generate_themes_header($self),
            version   => $self->LRR_VERSION
        );
    } else {
        $self->redirect_to('index');
    }
}

sub edit_tankoubon {
    my ( $self, $id ) = @_;

    # full_data is used to get the archive titles for the edit page. get_tankoubon also returns the
    # tank's own name/summary/tags, so a separate metadata fetch is unnecessary on the Postgres side.
    my ( $total, $filtered, %tank ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon( $id, 1 );

    unless (%tank) {
        $self->redirect_to('index');
        return;
    }

    my @archives   = @{ $tank{archives}  // [] };
    my @full_data  = @{ $tank{full_data} // [] };

    my $name    = $tank{name}    // "";
    my $tags    = $tank{tags}    // "";
    my $summary = $tank{summary} // "";

    $self->render(
        template      => "edit",
        id            => $id,
        arctitle      => $name,
        tags          => $tags,
        summary       => $summary,
        is_tank       => 1,
        archives      => \@archives,
        archive_data  => \@full_data,
        title         => $self->LRR_CONF->get_htmltitle,
        descstr       => $self->LRR_DESC,
        csshead       => generate_themes_header($self),
        version       => $self->LRR_VERSION
    );
}

1;
