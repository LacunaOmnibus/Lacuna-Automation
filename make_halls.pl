#!/usr/bin/perl

use strict;

use Carp;
use Client;
use Getopt::Long;
use IO::Handle;
use JSON::PP;
use List::Util;

autoflush STDOUT 1;
autoflush STDERR 1;

my $config_name = "config.json";
my @body_name;
my $ship_name;
my $for_name;
my $equalize = 0;
my $debug = 0;
my $quiet = 0;
my $hall_count = 0;
my $hall_max = 0;
my $low = 0;
my $high = 0;
my $reserve;
my %made;

GetOptions(
  "config=s"    => \$config_name,
  "body=s"      => \@body_name,
  "count=i"     => \$hall_count,
  "max=i"       => \$hall_max,
  "reserve=i"   => \$reserve,
  "for=s"       => \$for_name,
  "a=i"         => \$low,
  "z=i"         => \$high,
  "debug"       => \$debug,
  "quiet"       => \$quiet,
) or die "$0 --config=foo.json --body=Bar\n";

if ($high && $low) {
  $hall_count = ($hall_count || 1) * (($high * ($high + 1) / 2) - ($low * ($low + 1) / 2));
  print "Making $hall_count halls.\n";
}

die "Must specify body\n" if ( $hall_count || $hall_max ) && !@body_name;

if ($hall_max) { $reserve //= 1 }

my $client = Client->new(config => $config_name);
eval {
  warn "Getting empire status\n" if $debug;
  my $planets = $client->empire_status->{planets};

  my $for_id;
  if ($for_name) {
    $for_id = (grep { $planets->{$_} =~ /$for_name/ } keys(%$planets))[0];
    die "No matching planet for name $for_name\n" if $for_name && !$for_id;
    $for_name = $planets->{$for_id};
  }

  push(@body_name, sort values(%$planets)) unless @body_name;
  warn "Looking at bodies ".join(", ", @body_name)."\n" if $debug;
  for my $body_name (@body_name) { 
    eval {
      my $body_id;
      for my $id (keys(%$planets)) {
        $body_id = $id if $planets->{$id} =~ /$body_name/;
      }
      exit(1) if $quiet && !$body_id;
      die "No matching planet for name $body_name\n" unless $body_id;

      # get archaeology
      my $arch = eval { $client->find_building($body_id, "Archaeology Ministry"); };
      unless ($arch) {
        warn "No Archaeology Ministry on $planets->{$body_id}\n";
        next;
      }
      warn "Using Archaeology Ministry id $arch->{id}\n" if $debug;

      warn "Getting glyphs on $planets->{$body_id}\n" if $debug;
      my $summary = $client->call(archaeology => get_glyph_summary => $arch->{id});
      my %glyphs = map { $_->{name}, $_->{quantity} } @{$summary->{glyphs}};
      unless (%glyphs) {
        warn "No glyphs on $planets->{$body_id}\n";
        next;
      }

      my @recipes = (
        [ qw(goethite halite gypsum trona) ],
        [ qw(gold anthracite uraninite bauxite) ],
        [ qw(kerogen methane sulfur zircon) ],
        [ qw(monazite fluorite beryl magnetite) ],
        [ qw(rutile chromite chalcopyrite galena) ],
      );

      my %extra;
      my %possible;
      for my $recipe (@recipes) {
        my $min = List::Util::max(0, -$reserve + List::Util::min(map { $glyphs{$_} } @$recipe));
        $possible{$recipe} = $min;
        for my $glyph (@$recipe) {
          $extra{$glyph} = $glyphs{$glyph} - $min;
        }
      }

      my $max_halls = List::Util::sum(values(%possible));
      print "Can make $max_halls halls with ".List::Util::sum(values(%extra))." unmatched glyphs on $planets->{$body_id}.\n";

      die "Insufficient glyphs to make $hall_count halls\n" if $max_halls < $hall_count;

      while ( $max_halls > ( $hall_max || $hall_count ) ) {
        for my $recipe (@recipes) {
          last if $max_halls <= ( $hall_max || $hall_count );
          if ($possible{$recipe}) { $possible{$recipe}--; $max_halls--; }
        }
      }

      for my $recipe (@recipes) {
        while ($possible{$recipe}) {
          my $count = List::Util::min(50, $possible{$recipe});
          print "Making $count halls with ".join(", ", @$recipe)."\n";
          $possible{$recipe} -= $count;
          my $result = eval { $client->call(archaeology => assemble_glyphs => $arch->{id}, $recipe, $count); };
          if ($result->{item_name} eq "Halls of Vrbansk") {
            $made{$body_id} += $count;
          } else {
            print "Failed to make hall!\n";
          }
        }
      }

      if ($for_id && $made{$body_id}) {
        
        my $trade = eval { $client->find_building($body_id, "Trade Ministry"); };
        unless ($trade) {
          warn "No Trade Ministry on $planets->{$body_id}\n";
          next;
        }
        warn "Using Trade Ministry id $trade->{id}\n" if $debug;

        my $plans = $client->call(trade => get_plans => $trade->{id});
        my $psize = $plans->{cargo_space_used_each};
        my @plans = grep { $_->{name} eq "Halls of Vrbansk" } @{$plans->{plans}};
        $#plans = $made{$body_id} - 1 if @plans > $made{$body_id};

        my @ships = @{$client->call(trade => get_trade_ships => $trade->{id}, $for_id)->{ships}};
        # Avoid ships already allocated to trade routes
        @ships = grep { $_->{name} !~ /(Alpha|Beta|Gamma|Delta)$/ } @ships;

        $_->{plan_count} = int($_->{hold_size} / $psize) for @ships;

        # Choose fast ships sufficient to carry all the plans
        @ships = sort { $b->{speed} <=> $a->{speed} } @ships;
        my $top = 0;
        my $move_count = $ships[0]{plan_count};
        $move_count += $ships[++$top]{plan_count} while $top < $#ships && $move_count < $made{$body_id};
        $#ships = $top;
        print "Can only ship $move_count halls. :-(\n" if $move_count < $made{$body_id};

        # Choose the big ships from among the sufficient chosen ships (and free up any extra fast small ships)
        @ships = sort { $b->{hold_size} <=> $a->{hold_size} } @ships;
        $top = 0;
        $move_count = $ships[0]{plan_count};
        $move_count += $ships[++$top]{plan_count} while $top < $#ships && $move_count < $made{$body_id};
        $#ships = $top;

        for my $ship (@ships) {
          my @items;
          push(@items, { type => "plan", plan_id => (shift(@plans))->{id} }) while @plans && @items < $ship->{plan_count};
          print "Pushing ".scalar(@items)." halls to $for_name on $ship->{name}.\n";
          $client->trade_push($trade->{id}, $for_id, \@items, { ship_id => $ship->{id}, stay => 0 });
        }
      }
    }
  }
};

exit( ! %made );
