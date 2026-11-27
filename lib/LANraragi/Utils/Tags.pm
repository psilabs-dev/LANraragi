package LANraragi::Utils::Tags;

use strict;
use warnings;
use utf8;
no warnings 'experimental';

use LANraragi::Utils::String qw(trim trim_CRLF);

# Functions related to the Tag system.
use Exporter 'import';
our @EXPORT_OK = qw( unflat_tagrules replace_CRLF restore_CRLF tags_rules_to_array rewrite_tags build_tag_replace_hash split_tags_to_array join_tags_to_string merge_tank_tags );

sub is_null_or_empty {
    return !length(shift);
}

sub replace_CRLF {
    my ($val) = @_;
    $val =~ s/\x{d}\x{a}/;/g if ($val);
    return $val;
}

sub restore_CRLF {
    my ($val) = @_;
    $val =~ s/;/\x{d}\x{a}/g if ($val);
    return $val;
}

sub unflat_tagrules {
    my ($flattened_rules) = @_;
    my @tagrules = ();
    while ( @{ $flattened_rules || [] } ) {
        push( @tagrules, [ splice( @$flattened_rules, 0, 3 ) ] );
    }
    return @tagrules;
}

sub split_tags_to_array {
    my ($tags_string) = @_;
    my @tags = split( ',', $tags_string );
    foreach my $tags (@tags) {
        $tags = trim($tags);
        $tags = trim_CRLF($tags);
    }
    return @tags;
}

sub merge_tank_tags {
    my ( $tank_tags_str, $archive_tags_list ) = @_;
    my @own_tags = split_tags_to_array($tank_tags_str);

    # Build set of own tags for deduplication (case-insensitive)
    my %own_tags_lc = map { lc($_) => 1 } @own_tags;

    # Track date-type tags for coalescing (date_added and timestamp)
    my %own_date_tags;
    my %max_imputed_dates;

    # Check if tank has its own date_added or timestamp tags
    foreach my $t (@own_tags) {
        if ( $t =~ /^(date_added|timestamp):(\d+)$/i ) {
            $own_date_tags{ lc($1) } = 1;
        }
    }

    # Parse archive tags, deduplicate, exclude own_tags
    my %seen;
    my @imputed_tags;
    foreach my $tags_str (@$archive_tags_list) {
        next unless defined $tags_str && $tags_str ne "";
        foreach my $t ( split( /,/, $tags_str ) ) {
            $t = trim($t);
            next if $t eq "";
            my $t_lc = lc($t);

            # Handle date-type tags specially - track max value per namespace
            if ( $t =~ /^(date_added|timestamp):(\d+)$/i ) {
                my ( $ns, $val ) = ( lc($1), $2 );
                if ( !exists $max_imputed_dates{$ns} || $val > $max_imputed_dates{$ns}{value} ) {
                    $max_imputed_dates{$ns} = { value => $val, tag => $t };
                }
                next;
            }

            next if $seen{$t_lc}++;
            next if $own_tags_lc{$t_lc};
            push @imputed_tags, $t;
        }
    }

    # Add winning imputed date tags (only if tank has no own tag for that namespace)
    foreach my $ns ( keys %max_imputed_dates ) {
        if ( !exists $own_date_tags{$ns} ) {
            push @imputed_tags, $max_imputed_dates{$ns}{tag};
        }
    }

    return { own_tags => \@own_tags, imputed_tags => \@imputed_tags };
}

sub join_tags_to_string {
    return join( ',', @_ );
}

sub tags_rules_to_array {
    my ($text_rules) = @_;
    my @rules;
    my @lines = split( '\n', $text_rules );
    foreach my $line (@lines) {
        my ( $match, $value ) = split( '->', $line );
        $match = trim($match);
        $value = trim($value);
        if ( !is_null_or_empty($match) ) {

            my $rule_type;
            if ( !$value && $match =~ m/^-.*:\*$/ ) {
                $rule_type = 'remove_ns';
                $match     = substr( $match, 1, length($match) - 3 );
            } elsif ( !$value && $match =~ m/^-/ ) {
                $rule_type = 'remove';
                $match     = substr( $match, 1 );
            } elsif ( !$value && $match =~ m/^~/ ) {
                $rule_type = 'strip_ns';
                $match     = substr( $match, 1 );
            } elsif ( $match =~ m/:\*$/ && $value =~ m/:\*$/ ) {
                $rule_type = 'replace_ns';
                $match     = substr( $match, 0, length($match) - 2 );
                $value     = substr( $value, 0, length($value) - 2 );
            } elsif ( $line =~ m/=>/ ) {
                # process hash_replace rule
                ( $match, $value ) = split( '=>', $line );
                $rule_type = 'hash_replace';
                $match     = trim($match);
                $value     = trim($value);
            }
            elsif ( !$value ) {
                $rule_type = 'remove';    # blacklist mode
            } else {
                $rule_type = 'replace';
            }

            push( @rules, [ $rule_type, lc $match, $value || '' ] ) if ($rule_type);
        }
    }
    return @rules;
}

# build hash_replace rules and return the remaining rules
sub build_tag_replace_hash {
    my ($rules) = @_;
    my %hash_replace_rules;
    my @other_rules;

    foreach my $rule (@$rules) {
        if ( $rule->[0] eq 'hash_replace' ) {
            $hash_replace_rules{ lc $rule->[1] } = $rule->[2];
        }
        else {
            push( @other_rules, $rule );
        }
    }

    return ( \@other_rules, \%hash_replace_rules );
}

sub rewrite_tags {
    my ( $tags, $rules, $hash_replace_rules ) = @_;
    return @$tags if ( !@$rules );

    unless ( defined $hash_replace_rules ) {
        ( $rules, $hash_replace_rules ) = build_tag_replace_hash($rules);
    }

    my @parsed_tags;
    foreach my $tag (@$tags) {
        my $new_tag = apply_rules( $tag, $rules, $hash_replace_rules );
        push( @parsed_tags, $new_tag ) if defined $new_tag;
    }
    return @parsed_tags;
}

sub apply_rules {
    my ( $tag, $rules, $replace_hash ) = @_;
    foreach my $rule (@$rules) {
        my $name  = $rule->[0];
        my $match = $rule->[1];
        my $value = $rule->[2];
        if ( $name eq 'remove' )        { return if ( lc $tag eq $match ); }
        elsif ( $name eq 'remove_ns' )  { return if ( $tag =~ m/^$match:/i ); }
        elsif ( $name eq 'replace_ns' ) { $tag =~ s/^\Q$match:/$value\:/i; }
        elsif ( $name eq 'strip_ns' )   { $tag =~ s/^\Q$match://i; }
        else { $tag = $value if ( lc $tag eq $match ); }
    }
    if ( exists $replace_hash->{ lc $tag } ) {
        $tag = $replace_hash->{ lc $tag };
    }
    return $tag;
}

1;
