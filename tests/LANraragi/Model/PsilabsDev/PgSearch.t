use strict;
use warnings;
use Test::More;

plan skip_all => 'Set LRR_POSTGRES_HOST to run PostgreSQL search tests' unless $ENV{LRR_POSTGRES_HOST};

require LANraragi::Model::PsilabsDev::PgSearch;
require LANraragi::Utils::PsilabsDev::Postgres;

sub fixture_dbh {
    my $dbh = LANraragi::Utils::PsilabsDev::Postgres::get_postgresql_dbh();
    $dbh->do('CREATE TEMP TABLE lrr_archive (arcid text PRIMARY KEY, lastreadtime integer)');
    $dbh->do('CREATE TEMP TABLE lrr_tank (tankid text PRIMARY KEY)');
    $dbh->do('CREATE TEMP TABLE lrr_tank_to_archive_map (arcid text, tankid text)');
    $dbh->do(q{INSERT INTO lrr_archive VALUES ('recent', 80), ('old', 20), ('unread', 0), ('member1', 10), ('member2', 60)});
    $dbh->do(q{INSERT INTO lrr_tank VALUES ('TANK_read'), ('TANK_empty')});
    $dbh->do(q{INSERT INTO lrr_tank_to_archive_map VALUES ('member1', 'TANK_read'), ('member2', 'TANK_read')});
    return $dbh;
}

{
    no warnings qw(once redefine);
    local *LANraragi::Model::PsilabsDev::PgSearch::get_logger = sub { Mojo::Log->new(level => "error") };
    local *LANraragi::Model::PsilabsDev::PgSearch::get_dbh = \&fixture_dbh;
    local *LANraragi::Model::Config::get_pagesize = sub { 2 };

    my $search = sub {
        my ( $filter, $start, $reverse, $grouped ) = @_;
        return [ LANraragi::Model::PsilabsDev::PgSearch::do_search( $filter, '', $start, 'lastread', $reverse, 0, 0, $grouped, 0 ) ];
    };

    is_deeply( $search->( '', 0, 0, 1 ), [ 5, 5, 'recent', 'TANK_read' ], 'First page ranks archives and tanks together' );
    is_deeply( $search->( '', 2, 0, 1 ), [ 5, 5, 'old', 'TANK_empty' ], 'Second page puts unread entries after every read entry' );
    is_deeply( $search->( '', 1, 1, 1 ), [ 5, 5, 'TANK_read', 'recent' ], 'Reverse order keeps unread entries at the end' );
    is_deeply( $search->( 'lastread:>0', 4, 0, 1 ), [ 5, 3 ], 'Offset beyond results retains the filtered count' );
    is_deeply( $search->( 'lastread:60', -1, 0, 1 ), [ 5, 1, 'TANK_read' ], 'Tank timestamp is the latest member timestamp' );
    is_deeply( $search->( '-lastread:>=60', -1, 1, 1 ), [ 5, 3, 'old', 'TANK_empty', 'unread' ], 'Negated timestamp filter includes unread entries' );
    is_deeply( $search->( 'lastread:<=20', -1, 0, 0 ), [ 5, 3, 'old', 'member1', 'unread' ], 'Ungrouped filtering includes individual tank members' );

    my @clauses = ( { filter => 'lastread:60' }, { filter => 'lastread:>60' } );
    my @result = LANraragi::Model::PsilabsDev::PgSearch::do_composite_search( \@clauses, 0, 'lastread', 0, 1 );
    is_deeply( \@result, [ 5, 2, 'recent', 'TANK_read' ], 'Composite clauses apply timestamp predicates to both entity types' );
}

done_testing();
