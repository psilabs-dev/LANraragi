package LANraragi::Controller::Index;
use Mojo::Base 'Mojolicious::Controller';

use utf8;
use URI::Escape;
use Encode;
use File::Basename;

use LANraragi::Utils::Generic qw(generate_themes_header get_authenticator);
use LANraragi::Model::PsilabsDev::PgCategory;
use LANraragi::Model::PsilabsDev::PgArchive;

# This endpoint is technically superseded by /api/search/random, but it's still useful in the Reader.
sub random_archive {
    my $self = shift;

    # Get a random archive ID from Postgres
    my $archive = LANraragi::Model::PsilabsDev::PgArchive::get_random_archive();

    if ( defined($archive) ) {
        $self->LRR_LOGGER->debug("Found random archive: $archive");
        # Redirect to the reader with the archive ID as parameter
        $self->redirect_to( '/reader?id=' . $archive );
    } else {
        # No archives available or none have valid files
        $self->LRR_LOGGER->warn("No random archive found");
        $self->redirect_to('/');
    }
}

# Render the index template with a few prefilled arguments.
# Most of the work is done in JS these days.
sub index {

    my $self = shift;

    #Checking if the user still has the default password enabled
    my $hash = $self->LRR_CONF->get_password;

    if ( $hash =~ /{CRYPT}(.*)/ ) { # Convert RFC 2307 to bare hash
        $hash = $1;
    }

    my $passcheck = ( get_authenticator->verify_password( "kamimamita", $hash ) && $self->LRR_CONF->enable_pass );

    my $userlogged = $self->LRR_CONF->enable_pass == 0 || $self->session('is_logged');

    # Get static category list to populate the right-click menu
    my @categories = LANraragi::Model::PsilabsDev::PgCategory::get_static_category_list();

    $self->render(
        template     => "index",
        version      => $self->LRR_VERSION,
        title        => $self->LRR_CONF->get_htmltitle,
        descstr      => $self->LRR_DESC,
        userlogged   => $userlogged,
        categories   => \@categories,
        motd         => $self->LRR_CONF->get_motd,
        csshead      => generate_themes_header($self),
        usingdefpass => $passcheck
    );
}

1;
