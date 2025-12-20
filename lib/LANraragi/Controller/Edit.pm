package LANraragi::Controller::Edit;
use Mojo::Base 'Mojolicious::Controller';

use File::Basename;
use Encode;
use Template;
use Mojo::Util qw(xml_escape);

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Utils::Plugins qw(get_plugins);
use LANraragi::Utils::PsilabsDev::PgDatabase qw(get_archive);

sub index {
    my $self = shift;

    #Does the passed file exist in the database?
    my $id = $self->req->param('id');

    my %hash = get_archive($id);

    if ( %hash ) {
        my ( $name, $title, $tags, $summary, $file, $thumbhash ) = @hash{qw(name title tags summary file thumbhash)};

        #Build plugin listing
        my @pluginlist = get_plugins("metadata");

        $self->render(
            template  => "edit",
            id        => $id,
            name      => $name,
            arctitle  => xml_escape($title),
            tags      => xml_escape($tags),
            summary   => xml_escape($summary),
            file      => decode_utf8($file),
            thumbhash => $thumbhash,
            plugins   => \@pluginlist,
            title     => $self->LRR_CONF->get_htmltitle,
            descstr   => $self->LRR_DESC,
            csshead   => generate_themes_header($self),
            version   => $self->LRR_VERSION
        );
    } else {
        $self->redirect_to('index');
    }
}

1;
