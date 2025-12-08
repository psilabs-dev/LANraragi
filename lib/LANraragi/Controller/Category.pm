package LANraragi::Controller::Category;
use Mojo::Base 'Mojolicious::Controller';

use utf8;
use URI::Escape;
use Encode;
use Mojo::Util qw(xml_escape);

use LANraragi::Utils::Generic qw(generate_themes_header);
use LANraragi::Model::PsilabsDev::PgArchive;
use LANraragi::Model::PsilabsDev::PgTankoubon;

# Go through the archives in the content directory and build the template at the end.
sub index {

    my $self  = shift;

    my $userlogged = $self->LRR_CONF->enable_pass == 0 || $self->session('is_logged');

    my @idlist = LANraragi::Model::PsilabsDev::PgArchive::generate_archive_list();
    #Parse the archive list and build <li> elements accordingly.
    my $arclist = "";

    #Only show IDs that still have their files present.
    foreach my $arc (@idlist) {
        my $title = xml_escape($arc->{title});
        my $id = xml_escape($arc->{arcid});

        $arclist .=
          "<li><input type='checkbox' name='archive' id='$id' class='archive' onchange='Category.updateArchiveInCategory(this.id, this.checked)'>";
        $arclist .= "<label for='$id'> $title</label></li>";
    }

    # Build tank list
    my ( $total, $filtered, @tanks ) = LANraragi::Model::PsilabsDev::PgTankoubon::get_tankoubon_list(-1);
    my $tanklist = "";

    foreach my $tank (@tanks) {
        my $title = xml_escape( %$tank{name} );
        my $id    = xml_escape( %$tank{id} );

        $tanklist .=
          "<li><input type='checkbox' name='archive' id='$id' class='archive' onchange='Category.updateArchiveInCategory(this.id, this.checked)'>";
        $tanklist .= "<label for='$id'> $title</label></li>";
    }

    $self->render(
        template => "category",
        arclist  => $arclist,
        tanklist => $tanklist,
        title    => $self->LRR_CONF->get_htmltitle,
        descstr  => $self->LRR_DESC,
        csshead  => generate_themes_header($self),
        version  => $self->LRR_VERSION
    );
}

1;
